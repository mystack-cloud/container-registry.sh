#!/bin/sh
# container-registry.sh - Pull and push container images without Docker
# OCI/Docker Registry API in pure shell (curl + jq). Domain: container-registry.sh
#
# Usage:
#   container-registry.sh pull [OPTIONS] IMAGE [OUTPUT.tar.gz]
#   container-registry.sh push [OPTIONS] IMAGE FILE.tar[.gz]
#   container-registry.sh -h | --help
#
# Commands:
#   pull   Download image from registry to a Docker-format tar (optional .tar.gz)
#   push   Upload a Docker-format tar to the registry
#
# Global options:
#   -u, --user USER[:PASSWORD]   Registry credentials
#   -q, --quiet                  Less output
#   -h, --help                   Show help

set -e

ME="${0##*/}"

# --- Dependencies ---
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$ME: required command not found: $cmd" >&2
    exit 1
  fi
done

# --- Defaults and state ---
REGISTRY=""
REPOSITORY=""
REFERENCE=""
IMAGE_REF=""
OUTPUT_FILE=""
DO_GZIP=1
QUIET=0
REG_USER=""
REG_PASS=""
REGISTRY_TOKEN_FILE=""
TMPDIR="${TMPDIR:-/tmp}"
WORKDIR=""
CURL_OPTS="--silent --show-error --location --fail"

# --- Help ---
show_help() {
  sed -n '2,22p' "$0" | sed 's/^# \?//'
  echo "Examples:"
  echo "  $ME pull alpine:3.19"
  echo "  $ME pull -o img.tar docker.io/library/nginx:alpine"
  echo "  $ME push -u user:token ghcr.io/myorg/img:v1 image.tar.gz"
  echo "Install: curl https://get.container-registry.sh | sh -s"
  exit 0
}

log() { [ "$QUIET" = 1 ] || echo "$@"; }
log_err() { echo "$ME: $*" >&2; }

# --- Parse image reference [registry/]repository[:tag|@digest] ---
parse_image() {
  local img="$1"
  local rest=""
  IMAGE_REF="$img"

  case "$img" in
    *@sha256:*)
      rest="${img#*@sha256:}"
      REFERENCE="sha256:${rest}"
      img="${img%%@sha256:*}"
      ;;
    *:*)
      rest="${img#*:}"
      case "$img" in
        */*) REFERENCE="${img##*:}"; img="${img%:*}" ;;
        *)   REFERENCE="$rest"; img="${img%%:*}" ;;
      esac
      ;;
    *)
      REFERENCE="latest"
      ;;
  esac

  [ -n "$img" ] || { log_err "invalid image: $IMAGE_REF"; exit 1; }

  case "$img" in
    */*/*) REGISTRY="${img%%/*}"; REPOSITORY="${img#*/}" ;;
    */*)
      case "$img" in
        *.*.*|*:*) REGISTRY="${img%%/*}"; REPOSITORY="${img#*/}" ;;
        *) REGISTRY=""; REPOSITORY="$img" ;;
      esac
      ;;
    *) REPOSITORY="$img"; REGISTRY="" ;;
  esac

  if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "docker.io" ]; then
    REGISTRY="registry-1.docker.io"
    case "$REPOSITORY" in */*) ;; *) REPOSITORY="library/$REPOSITORY" ;; esac
  fi
  [ -n "$REFERENCE" ] || REFERENCE="latest"
}

registry_base() { echo "https://${REGISTRY}"; }

# --- Bearer token (reads from headers file to avoid arg length limits) ---
get_bearer_token() {
  local headers_file="$1"
  local token_file="$2"
  local auth_header realm service scope url resp_file

  auth_header=$(grep -i 'www-authenticate' "$headers_file" 2>/dev/null | head -1 | sed 's/^[^:]*: *//i' | tr -d '\r')
  [ -n "$auth_header" ] || return 0

  realm=$(echo "$auth_header" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(echo "$auth_header" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  scope=$(echo "$auth_header" | sed -n 's/.*scope="\([^"]*\)".*/\1/p')
  [ -n "$realm" ] || return 0

  # For push we may need to request push scope if only pull was in challenge
  url="$realm?service=${service}&scope=${scope}"
  resp_file="${TMPDIR:-/tmp}/registry_token_resp.$$.json"
  curl --silent --show-error ${REG_USER:+-u "$REG_USER:$REG_PASS"} "$url" -o "$resp_file" 2>/dev/null || true
  if [ -n "$token_file" ] && [ -s "$resp_file" ]; then
    jq -r '.token // .access_token // empty' "$resp_file" > "$token_file"
  fi
  rm -f "$resp_file" 2>/dev/null || true
}

# --- GET with optional Bearer auth ---
registry_get() {
  local path="$1"; shift
  local base url headers_file body_file
  base=$(registry_base)
  url="${base}/v2/${REPOSITORY}/${path}"
  headers_file="${WORKDIR}/headers.$$"
  body_file="${WORKDIR}/body.$$"

  _do_get() {
    local opts="--silent --show-error --location -D $headers_file -o $body_file"
    if [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ]; then
      printf 'Authorization: Bearer ' > "${WORKDIR}/.auth_header"
      tr -d '\n\r' < "$REGISTRY_TOKEN_FILE" >> "${WORKDIR}/.auth_header"
      curl $opts -H "@${WORKDIR}/.auth_header" "$@" "$url" 2>/dev/null || true
    else
      curl $opts "$@" "$url" 2>/dev/null || true
    fi
  }

  _do_get
  if grep -qi 'www-authenticate' "$headers_file" 2>/dev/null; then
    get_bearer_token "$headers_file" "${WORKDIR}/.token"
    if [ -f "${WORKDIR}/.token" ] && [ -s "${WORKDIR}/.token" ]; then
      REGISTRY_TOKEN_FILE="${WORKDIR}/.token"
      _do_get "$@"
    fi
  fi
  cat "$body_file" 2>/dev/null || true
}

# --- HEAD with Bearer auth (for push: check if blob exists) ---
registry_head() {
  local path="$1"
  local base url headers_file
  base=$(registry_base)
  url="${base}/v2/${REPOSITORY}/${path}"
  headers_file="${WORKDIR}/headers.$$"
  if [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ]; then
    printf 'Authorization: Bearer ' > "${WORKDIR}/.auth_header"
    tr -d '\n\r' < "$REGISTRY_TOKEN_FILE" >> "${WORKDIR}/.auth_header"
    curl --silent --show-error --location -D "$headers_file" -o /dev/null -H "@${WORKDIR}/.auth_header" "$url" 2>/dev/null || true
  else
    curl --silent --show-error --location -D "$headers_file" -o /dev/null "$url" 2>/dev/null || true
  fi
  grep -q '^HTTP/[0-9.]* 200' "$headers_file" 2>/dev/null
}

# --- POST (for push: start blob upload) ---
registry_post() {
  local path="$1"
  local body_file="$2"
  local base url headers_file out_file
  base=$(registry_base)
  url="${base}/v2/${REPOSITORY}/${path}"
  headers_file="${WORKDIR}/headers.$$"
  out_file="${WORKDIR}/post_out.$$"
  if [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ]; then
    printf 'Authorization: Bearer ' > "${WORKDIR}/.auth_header"
    tr -d '\n\r' < "$REGISTRY_TOKEN_FILE" >> "${WORKDIR}/.auth_header"
    curl --silent --show-error -D "$headers_file" -o "$out_file" -X POST -H "@${WORKDIR}/.auth_header" -H "Content-Length: 0" "$url" 2>/dev/null || true
  else
    curl --silent --show-error -D "$headers_file" -o "$out_file" -X POST -H "Content-Length: 0" "$url" 2>/dev/null || true
  fi
  if grep -qi 'www-authenticate' "$headers_file" 2>/dev/null; then
    get_bearer_token "$headers_file" "${WORKDIR}/.token"
    if [ -f "${WORKDIR}/.token" ] && [ -s "${WORKDIR}/.token" ]; then
      REGISTRY_TOKEN_FILE="${WORKDIR}/.token"
      curl --silent --show-error -D "$headers_file" -o "$out_file" -X POST -H "@${WORKDIR}/.auth_header" -H "Content-Length: 0" "$url" 2>/dev/null || true
    fi
  fi
  grep -i '^Location:' "$headers_file" 2>/dev/null | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r\n'
}

# --- PUT with body (for push: complete blob upload, put manifest) ---
registry_put() {
  local url_or_path="$1"
  local body_file="$2"
  local base url headers_file
  case "$url_or_path" in
    http://*|https://*) url="$url_or_path" ;;
    *)
      base=$(registry_base)
      url="${base}/v2/${REPOSITORY}/${url_or_path}"
      ;;
  esac
  headers_file="${WORKDIR}/headers.$$"
  if [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ]; then
    printf 'Authorization: Bearer ' > "${WORKDIR}/.auth_header"
    tr -d '\n\r' < "$REGISTRY_TOKEN_FILE" >> "${WORKDIR}/.auth_header"
    curl --silent --show-error -D "$headers_file" -o /dev/null -X PUT -H "@${WORKDIR}/.auth_header" -H "Content-Type: application/octet-stream" --data-binary "@${body_file}" "$url" 2>/dev/null || true
  else
    curl --silent --show-error -D "$headers_file" -o /dev/null -X PUT -H "Content-Type: application/octet-stream" --data-binary "@${body_file}" "$url" 2>/dev/null || true
  fi
  if grep -qi 'www-authenticate' "$headers_file" 2>/dev/null; then
    get_bearer_token "$headers_file" "${WORKDIR}/.token"
    if [ -f "${WORKDIR}/.token" ] && [ -s "${WORKDIR}/.token" ]; then
      REGISTRY_TOKEN_FILE="${WORKDIR}/.token"
      curl --silent --show-error -D "$headers_file" -o /dev/null -X PUT -H "@${WORKDIR}/.auth_header" -H "Content-Type: application/octet-stream" --data-binary "@${body_file}" "$url" 2>/dev/null || true
    fi
  fi
  grep -qE '^HTTP/[0-9.]* (200|201)' "$headers_file" 2>/dev/null
}

# --- Compute sha256 digest of file (hex for Docker digest) ---
sha256_digest_hex() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    openssl dgst -sha256 "$f" | awk '{print $2}'
  fi
}

get_config_digest() { jq -r '.config.digest // empty' "$1"; }
get_layer_digests() { jq -r '.layers[]? | .digest' "$1"; }
get_manifest_list_digest() { jq -r '.manifests[0].digest // empty' "$1"; }
digest_to_name() { echo "$1" | sed 's/^sha256://'; }

# ========== PULL ==========
cmd_pull() {
  local manifest_file config_digest config_name layer_name manifest_path repotag
  WORKDIR=$(mktemp -d "${TMPDIR}/container-registry.XXXXXX")
  trap 'rm -rf "$WORKDIR"' EXIT

  manifest_file="${WORKDIR}/manifest.json"
  manifest_path="manifests/${REFERENCE}"
  log "Pulling ${IMAGE_REF} from ${REGISTRY}..."

  registry_get "$manifest_path" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.oci.image.index.v1+json' > "$manifest_file" || true

  if jq -e '.errors != null' "$manifest_file" >/dev/null 2>&1; then
    log_err "manifest fetch failed (auth or invalid image)"
    exit 1
  fi
  if ! [ -s "$manifest_file" ]; then
    log_err "failed to fetch manifest for ${REPOSITORY}:${REFERENCE}"
    exit 1
  fi

  if jq -e '.manifests != null' "$manifest_file" >/dev/null 2>&1; then
    local list_digest
    list_digest=$(get_manifest_list_digest "$manifest_file")
    [ -n "$list_digest" ] || { log_err "could not get digest from manifest list"; exit 1; }
    log "Resolving multi-arch image to digest ${list_digest}..."
    registry_get "manifests/${list_digest}" \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' > "$manifest_file" || true
    if ! [ -s "$manifest_file" ] || jq -e '.errors != null' "$manifest_file" >/dev/null 2>&1; then
      log_err "failed to fetch image manifest"
      exit 1
    fi
  fi

  config_digest=$(get_config_digest "$manifest_file")
  [ -n "$config_digest" ] || { log_err "could not parse config digest"; exit 1; }
  config_name=$(digest_to_name "$config_digest")
  log "Fetching config ${config_digest}..."
  registry_get "blobs/${config_digest}" > "${WORKDIR}/${config_name}.json"
  [ -s "${WORKDIR}/${config_name}.json" ] || { log_err "failed to fetch config blob"; exit 1; }

  local layers_dir="${WORKDIR}/layers"
  mkdir -p "$layers_dir"
  get_layer_digests "$manifest_file" > "${WORKDIR}/layer_list"
  local count=0
  while read -r layer_digest; do
    [ -z "$layer_digest" ] && continue
    count=$((count + 1))
    layer_name=$(digest_to_name "$layer_digest")
    mkdir -p "${layers_dir}/${layer_name}"
    log "Fetching layer $count ${layer_digest}..."
    registry_get "blobs/${layer_digest}" > "${layers_dir}/${layer_name}/layer.tar"
    [ -s "${layers_dir}/${layer_name}/layer.tar" ] || { log_err "failed to fetch layer ${layer_digest}"; exit 1; }
  done < "${WORKDIR}/layer_list"

  repotag="${REPOSITORY}:${REFERENCE}"
  {
    printf '%s\n' "["
    printf '  {"Config":"%s.json","RepoTags":["%s"],"Layers":[' "$config_name" "$repotag"
    local i=0
    while read -r layer_digest; do
      [ -z "$layer_digest" ] && continue
      layer_name=$(digest_to_name "$layer_digest")
      [ $i -gt 0 ] && printf ","
      printf '"%s/layer.tar"' "${layer_name}"
      i=$((i + 1))
    done < "${WORKDIR}/layer_list"
    printf "]}\n]\n"
  } > "${WORKDIR}/manifest.json"

  log "Writing archive to ${OUTPUT_FILE}..."
  ( cd "$WORKDIR" && tar -cf - manifest.json "${config_name}.json" ) > "${WORKDIR}/out.tar"
  ( cd "${layers_dir}" && tar -rf "${WORKDIR}/out.tar" . )
  mv "${WORKDIR}/out.tar" "${OUTPUT_FILE}"

  if [ "$DO_GZIP" = 1 ]; then
    gzip -f "${OUTPUT_FILE}"
    log "Created ${OUTPUT_FILE}.gz"
  else
    log "Created ${OUTPUT_FILE}"
  fi
}

# ========== PUSH ==========
cmd_push() {
  local tar_file="$1"
  local extract_dir manifest_json config_path config_digest config_size
  local layer_path layer_digest layer_size upload_url base i
  local manifest_v2 config_sha layers_json

  [ -f "$tar_file" ] || { log_err "file not found: $tar_file"; exit 1; }

  WORKDIR=$(mktemp -d "${TMPDIR}/container-registry-push.XXXXXX")
  trap 'rm -rf "$WORKDIR"' EXIT

  extract_dir="${WORKDIR}/extract"
  mkdir -p "$extract_dir"
  if [ "${tar_file%.gz}" != "$tar_file" ]; then
    gunzip -c "$tar_file" | ( cd "$extract_dir" && tar -xf - )
  else
    ( cd "$extract_dir" && tar -xf "$tar_file" )
  fi

  # Docker manifest.json is array with one entry: Config, RepoTags, Layers
  manifest_json="${extract_dir}/manifest.json"
  [ -f "$manifest_json" ] || { log_err "invalid image tar: no manifest.json"; exit 1; }
  config_path="${extract_dir}/$(jq -r '.[0].Config' "$manifest_json")"
  [ -f "$config_path" ] || { log_err "invalid image tar: config not found"; exit 1; }

  # Get token with push scope (required for push)
  local hf="${WORKDIR}/headers.$$"
  base=$(registry_base)
  curl --silent -D "$hf" -o /dev/null "${base}/v2/${REPOSITORY}/blobs/uploads/" -X POST 2>/dev/null || true
  if grep -qi 'www-authenticate' "$hf" 2>/dev/null; then
    get_bearer_token "$hf" "${WORKDIR}/.token"
    if [ -f "${WORKDIR}/.token" ] && [ -s "${WORKDIR}/.token" ]; then
      REGISTRY_TOKEN_FILE="${WORKDIR}/.token"
    fi
  fi
  # Explicitly request token with push scope (auth server may return pull-only otherwise)
  if [ -n "$REG_USER" ]; then
    local realm service token_url
    realm="https://auth.docker.io/token"; service="registry.docker.io"
    [ "$REGISTRY" != "registry-1.docker.io" ] && realm="${base}/token" && service="${REGISTRY}"
    token_url="${realm}?service=${service}&scope=repository:${REPOSITORY}:push,pull"
    curl -sS ${REG_USER:+-u "$REG_USER:$REG_PASS"} "$token_url" 2>/dev/null | jq -r '.token // .access_token // empty' > "${WORKDIR}/.token"
    [ -s "${WORKDIR}/.token" ] && REGISTRY_TOKEN_FILE="${WORKDIR}/.token"
  fi
  [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ] || { log_err "push requires authentication (-u user:password)"; exit 1; }

  log "Pushing ${IMAGE_REF}..."

  # Upload config blob
  config_sha="sha256:$(sha256_digest_hex "$config_path")"
  config_size=$(wc -c < "$config_path")
  if ! registry_head "blobs/${config_sha}"; then
    log "Uploading config ${config_sha}..."
    upload_url=$(registry_post "blobs/uploads/" "")
    [ -n "$upload_url" ] || { log_err "failed to start config upload"; exit 1; }
    base=$(registry_base)
    case "$upload_url" in
      http*) ;;
      *) upload_url="${base}${upload_url}" ;;
    esac
    registry_put "${upload_url}?digest=${config_sha}" "$config_path" || { log_err "failed to upload config"; exit 1; }
  else
    log "Config ${config_sha} already exists"
  fi

  # Build layers array for manifest and upload each layer
  jq -r '.[0].Layers[]' "$manifest_json" > "${WORKDIR}/layer_paths"
  layers_json=""
  i=0
  while read -r layer_rel; do
    [ -z "$layer_rel" ] && continue
    layer_path="${extract_dir}/${layer_rel}"
    [ -f "$layer_path" ] || { log_err "layer not found: $layer_rel"; exit 1; }
    layer_digest="sha256:$(sha256_digest_hex "$layer_path")"
    layer_size=$(wc -c < "$layer_path")
    if [ $i -gt 0 ]; then layers_json="${layers_json},"; fi
    layers_json="${layers_json}{\"mediaType\":\"application/vnd.docker.image.rootfs.diff.tar.gzip\",\"digest\":\"${layer_digest}\",\"size\":${layer_size}}"

    if ! registry_head "blobs/${layer_digest}"; then
      log "Uploading layer ${layer_digest}..."
      upload_url=$(registry_post "blobs/uploads/" "")
      [ -n "$upload_url" ] || { log_err "failed to start layer upload"; exit 1; }
      case "$upload_url" in http*) ;; *) upload_url="$(registry_base)${upload_url}" ;; esac
      registry_put "${upload_url}?digest=${layer_digest}" "$layer_path" || { log_err "failed to upload layer ${layer_digest}"; exit 1; }
    else
      log "Layer ${layer_digest} already exists"
    fi
    i=$((i + 1))
  done < "${WORKDIR}/layer_paths"

  # Build and push manifest v2 schema2
  manifest_v2="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.docker.distribution.manifest.v2+json\",\"config\":{\"mediaType\":\"application/vnd.docker.container.image.v1+json\",\"digest\":\"${config_sha}\",\"size\":${config_size}},\"layers\":[${layers_json}]}"
  echo "$manifest_v2" > "${WORKDIR}/manifest_v2.json"

  log "Uploading manifest ${REFERENCE}..."
  base=$(registry_base)
  url="${base}/v2/${REPOSITORY}/manifests/${REFERENCE}"
  headers_file="${WORKDIR}/headers.$$"
  if [ -n "$REGISTRY_TOKEN_FILE" ] && [ -s "$REGISTRY_TOKEN_FILE" ]; then
    printf 'Authorization: Bearer ' > "${WORKDIR}/.auth_header"
    tr -d '\n\r' < "$REGISTRY_TOKEN_FILE" >> "${WORKDIR}/.auth_header"
    curl --silent --show-error -D "$headers_file" -o /dev/null -X PUT \
      -H "@${WORKDIR}/.auth_header" \
      -H "Content-Type: application/vnd.docker.distribution.manifest.v2+json" \
      --data-binary "@${WORKDIR}/manifest_v2.json" \
      "$url" 2>/dev/null || true
  else
    curl --silent --show-error -D "$headers_file" -o /dev/null -X PUT \
      -H "Content-Type: application/vnd.docker.distribution.manifest.v2+json" \
      --data-binary "@${WORKDIR}/manifest_v2.json" \
      "$url" 2>/dev/null || true
  fi
  if ! grep -qE '^HTTP/[0-9.]* (200|201)' "$headers_file" 2>/dev/null; then
    log_err "failed to push manifest"
    exit 1
  fi
  log "Pushed ${IMAGE_REF}"
}

# --- Default output for pull ---
default_output() {
  local base
  base=$(echo "${REPOSITORY}/${REFERENCE}" | tr '/:' '__')
  echo "${base}.tar"
}

# --- Main: parse global opts and command ---
COMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)
      REG_USER="${2:-}"
      REG_PASS="${REG_USER#*:}"
      [ "$REG_PASS" = "$REG_USER" ] && REG_PASS=""
      REG_USER="${REG_USER%%:*}"
      shift 2
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      show_help
      ;;
    pull|push)
      COMMAND="$1"
      shift
      break
      ;;
    -*)
      log_err "unknown option: $1"
      exit 1
      ;;
    *)
      log_err "expected command (pull or push); use -h for help"
      exit 1
      ;;
  esac
done

if [ -z "$COMMAND" ]; then
  [ $# -gt 0 ] && COMMAND="$1" && shift
fi
if [ -z "$COMMAND" ]; then
  log_err "usage: $ME pull IMAGE [OUTPUT] | $ME push IMAGE FILE.tar"
  exit 1
fi

case "$COMMAND" in
  pull)
    OUTPUT_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        --no-gzip) DO_GZIP=0; shift ;;
        -*) log_err "unknown option: $1"; exit 1 ;;
        *)
          if [ -z "$IMAGE_REF" ]; then
            parse_image "$1"
            shift
            [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && OUTPUT_FILE="$1" && shift
          else
            [ "${1#-}" = "$1" ] && OUTPUT_FILE="$1"
            shift
          fi
          ;;
      esac
    done
    [ -n "$IMAGE_REF" ] || { log_err "pull: missing IMAGE"; exit 1; }
    [ -n "$OUTPUT_FILE" ] || OUTPUT_FILE=$(default_output)
    if [ "$DO_GZIP" = 1 ] && [ "${OUTPUT_FILE%.gz}" = "$OUTPUT_FILE" ]; then
      [ "${OUTPUT_FILE%.tar}" = "$OUTPUT_FILE" ] && OUTPUT_FILE="${OUTPUT_FILE}.tar"
    fi
    cmd_pull
    ;;
  push)
    push_file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -*) log_err "unknown option: $1"; exit 1 ;;
        *)
          if [ -z "$IMAGE_REF" ]; then
            parse_image "$1"
            shift
          else
            push_file="$1"
            shift
            break
          fi
          ;;
      esac
    done
    [ -n "$IMAGE_REF" ] || { log_err "push: missing IMAGE"; exit 1; }
    [ -n "$push_file" ] || { log_err "push: missing FILE"; exit 1; }
    cmd_push "$push_file"
    ;;
  *)
    log_err "unknown command: $COMMAND"
    exit 1
    ;;
esac
