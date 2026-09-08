#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

required=(BUILD_COMMIT BUILD_NUMBER SPIN_VERSION_NAME ANDROID_UNSIGNED_REQUEST_ID SOURCE_CHECKOUT CONTROL_DIR TRUSTED_CI_REPOSITORY TRUSTED_CI_REF TRUSTED_CI_REVISION TRUSTED_CI_WORKFLOW_SHA256 TRUSTED_CI_JANITOR_SHA256 TRUSTED_GITHUB_MERGER GITHUB_API_USER GITHUB_API_TOKEN)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "ERROR: missing $name" >&2; exit 64; }
done
run_root="$(dirname "$CONTROL_DIR")"
case "$run_root" in /Users/yj/.jenkins/spin-android-runs/Spin-AOS-AAB/spin-android-run-*) ;; *) exit 64 ;; esac
test "$CONTROL_DIR" = "$run_root/control"
test "$SOURCE_CHECKOUT" = "$run_root/source"
test -d "$CONTROL_DIR" && test ! -L "$CONTROL_DIR" && test -O "$CONTROL_DIR"
test -d "$SOURCE_CHECKOUT" && test ! -L "$SOURCE_CHECKOUT" && test -O "$SOURCE_CHECKOUT"
test -z "${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_REPLACE_REF_BASE:-}"
export GIT_NO_REPLACE_OBJECTS=1
case "$BUILD_COMMIT" in ''|*[!0-9a-f]*) exit 64 ;; esac
test "${#BUILD_COMMIT}" = 40
case "$BUILD_NUMBER" in ''|*[!0-9]*) exit 64 ;; esac
node -e 'if(!/^jenkins-[0-9]+-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(process.env.ANDROID_UNSIGNED_REQUEST_ID)) throw new Error("invalid request nonce")'

cd "$CONTROL_DIR"
api_base="https://api.github.com/repos/$TRUSTED_CI_REPOSITORY"
github_api() {
  printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" |
    curl --config - -fsS --retry 3 --connect-timeout 10 --max-time 60 \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$1"
}
run_id=''
run_completed='false'
source_release_id=''
source_release_tag="spin-android-source-$ANDROID_UNSIGNED_REQUEST_ID"
recovery_journal="$run_root/recovery-journal.json"
cleanup_failures=''
cleanup_request() {
  method="$1"
  url="$2"
  http_code="$(printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" |
    curl --config - -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$url")"
  transport_status=$?
  case "$transport_status:$http_code" in
    0:2??|0:404) return 0 ;;
  esac
  cleanup_failures="${cleanup_failures}${method} ${url} transport=${transport_status} http=${http_code}\n"
  return 1
}
cleanup() {
  status=$?
  trap - EXIT
  set +e
  cleanup_failed=0
  if [ -n "$run_id" ] && [ "$run_completed" != true ]; then
    cleanup_request POST "$api_base/actions/runs/$run_id/cancel" || cleanup_failed=1
  fi
  if [ -n "$source_release_id" ]; then
    cleanup_request DELETE "$api_base/releases/$source_release_id" || cleanup_failed=1
  fi
  cleanup_request DELETE "$api_base/git/refs/tags/$source_release_tag" || cleanup_failed=1
  if [ "$cleanup_failed" -ne 0 ]; then
    CLEANUP_FAILURES="$cleanup_failures" RUN_ID="$run_id" SOURCE_RELEASE_ID="$source_release_id" SOURCE_RELEASE_TAG="$source_release_tag" ORIGINAL_STATUS="$status" RECOVERY_JOURNAL="$recovery_journal" node -e 'const fs=require("fs"); const value={format:1,createdAt:new Date().toISOString(),runId:process.env.RUN_ID||null,sourceReleaseId:process.env.SOURCE_RELEASE_ID||null,sourceReleaseTag:process.env.SOURCE_RELEASE_TAG,originalStatus:Number(process.env.ORIGINAL_STATUS),failures:process.env.CLEANUP_FAILURES.trim().split(/\n/).filter(Boolean)}; fs.writeFileSync(process.env.RECOVERY_JOURNAL,JSON.stringify(value)+"\n",{mode:0o400,flag:"wx"})' || true
    echo "ERROR: remote cleanup incomplete; recovery journal preserved at $recovery_journal" >&2
    exit 1
  fi
  rm -f "$recovery_journal"
  cd /
  rm -rf "$CONTROL_DIR" || status=1
  exit "$status"
}
trap cleanup EXIT

github_api "$api_base/contents/.github/workflows/spin-android-unsigned.yml?ref=$TRUSTED_CI_REVISION" > trusted-workflow.json
node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("trusted-workflow.json","utf8")); if(v.type!=="file"||v.path!==".github/workflows/spin-android-unsigned.yml") throw new Error("workflow identity mismatch"); fs.writeFileSync("trusted-workflow.yml",Buffer.from(v.content.replace(/\s/g,""),"base64"),{mode:0o400})'
test "$(shasum -a 256 trusted-workflow.yml | awk '{print $1}')" = "$TRUSTED_CI_WORKFLOW_SHA256"
github_api "$api_base/contents/.github/workflows/spin-ios-source-janitor.yml?ref=$TRUSTED_CI_REVISION" > trusted-janitor.json
node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("trusted-janitor.json","utf8")); if(v.type!=="file"||v.path!==".github/workflows/spin-ios-source-janitor.yml") throw new Error("janitor identity mismatch"); fs.writeFileSync("trusted-janitor.yml",Buffer.from(v.content.replace(/\s/g,""),"base64"),{mode:0o400})'
test "$(shasum -a 256 trusted-janitor.yml | awk '{print $1}')" = "$TRUSTED_CI_JANITOR_SHA256"
github_api "$api_base/actions/workflows/spin-ios-source-janitor.yml/runs?per_page=20" > janitor-runs.json
node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("janitor-runs.json","utf8")); if(!(v.workflow_runs||[]).some((r)=>r.head_sha===process.env.TRUSTED_CI_REVISION&&r.path===".github/workflows/spin-ios-source-janitor.yml"&&r.status==="completed"&&r.conclusion==="success"&&Date.parse(r.updated_at)>=Date.now()-48*60*60*1000)) throw new Error("no recent exact-revision janitor success")'

source_dir="$(mktemp -d "$CONTROL_DIR/source.XXXXXX")"
assert_repository_boundary() {
  repository="$1"
  expected_commit="$2"
  test "$(git -C "$repository" rev-parse --is-inside-work-tree)" = true
  test "$(git -C "$repository" rev-parse HEAD)" = "$expected_commit"
  test -z "$(git -C "$repository" for-each-ref --format='%(refname)' refs/replace/)"
  git_dir="$(git -C "$repository" rev-parse --absolute-git-dir)"
  test ! -e "$git_dir/info/grafts" && test ! -L "$git_dir/info/grafts"
  test ! -e "$git_dir/objects/info/alternates" && test ! -L "$git_dir/objects/info/alternates"
  test -z "$(git -C "$repository" config --show-origin --get-all core.alternateRefsCommand || true)"
}
assert_repository_boundary "$SOURCE_CHECKOUT" "$BUILD_COMMIT"
GAMEPACKAGES_COMMIT="$(git -C "$SOURCE_CHECKOUT" ls-tree "$BUILD_COMMIT" packages | awk '{print $3}')"
PHASERPACKAGES_COMMIT="$(git -C "$SOURCE_CHECKOUT" ls-tree "$BUILD_COMMIT" phaser-packages | awk '{print $3}')"
PLAYTEST_COMMIT="$(git -C "$SOURCE_CHECKOUT" ls-tree "$BUILD_COMMIT" vendor/playtest-platform | awk '{print $3}')"
assert_repository_boundary "$SOURCE_CHECKOUT/packages" "$GAMEPACKAGES_COMMIT"
assert_repository_boundary "$SOURCE_CHECKOUT/phaser-packages" "$PHASERPACKAGES_COMMIT"
assert_repository_boundary "$SOURCE_CHECKOUT/vendor/playtest-platform" "$PLAYTEST_COMMIT"
git -C "$SOURCE_CHECKOUT" archive "$BUILD_COMMIT" | tar -x -C "$source_dir"
mkdir -p "$source_dir/packages" "$source_dir/phaser-packages" "$source_dir/vendor/playtest-platform"
git -C "$SOURCE_CHECKOUT/packages" archive "$GAMEPACKAGES_COMMIT" | tar -x -C "$source_dir/packages"
git -C "$SOURCE_CHECKOUT/phaser-packages" archive "$PHASERPACKAGES_COMMIT" | tar -x -C "$source_dir/phaser-packages"
git -C "$SOURCE_CHECKOUT/vendor/playtest-platform" archive "$PLAYTEST_COMMIT" | tar -x -C "$source_dir/vendor/playtest-platform"
rm -f "$source_dir/.ci-source-manifest.json"
SOURCE_MANIFEST="$source_dir/.ci-source-manifest.json" GAMEPACKAGES_COMMIT="$GAMEPACKAGES_COMMIT" PHASERPACKAGES_COMMIT="$PHASERPACKAGES_COMMIT" PLAYTEST_COMMIT="$PLAYTEST_COMMIT" node -e 'const fs=require("fs"),flags=fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,fd=fs.openSync(process.env.SOURCE_MANIFEST,flags,0o400); try{fs.writeFileSync(fd,JSON.stringify({format:1,commit:process.env.BUILD_COMMIT,submodules:{gamePackages:process.env.GAMEPACKAGES_COMMIT,phaserPackages:process.env.PHASERPACKAGES_COMMIT,playtestPlatform:process.env.PLAYTEST_COMMIT}})+"\n")}finally{fs.closeSync(fd)}; const stat=fs.lstatSync(process.env.SOURCE_MANIFEST); if(!stat.isFile()||stat.isSymbolicLink()) throw new Error("unsafe source manifest")'
source_plain="$CONTROL_DIR/$source_release_tag.tar.gz"
tar -czf "$source_plain" -C "$source_dir" .
rm -rf "$source_dir"
SOURCE_PLAIN_SHA256="$(shasum -a 256 "$source_plain" | awk '{print $1}')"
export SOURCE_PLAIN_SHA256

OUTPUT_PRIVATE_KEY="$CONTROL_DIR/output-private.pem"
OUTPUT_PUBLIC_KEY="$CONTROL_DIR/output-public.pem"
export OUTPUT_PRIVATE_KEY OUTPUT_PUBLIC_KEY
node -e 'const crypto=require("crypto"),fs=require("fs"),p=crypto.generateKeyPairSync("rsa",{modulusLength:3072,publicKeyEncoding:{type:"spki",format:"pem"},privateKeyEncoding:{type:"pkcs8",format:"pem"}}); fs.writeFileSync(process.env.OUTPUT_PRIVATE_KEY,p.privateKey,{mode:0o400}); fs.writeFileSync(process.env.OUTPUT_PUBLIC_KEY,p.publicKey,{mode:0o400})'
OUTPUT_PUBLIC_KEY_B64="$(base64 < "$OUTPUT_PUBLIC_KEY" | tr -d '\n')"
export OUTPUT_PUBLIC_KEY_B64
node -e 'const fs=require("fs"); fs.writeFileSync("dispatch.json",JSON.stringify({ref:process.env.TRUSTED_CI_REF,inputs:{commit_sha:process.env.BUILD_COMMIT,build_number:process.env.BUILD_NUMBER,version_name:process.env.SPIN_VERSION_NAME,request_id:process.env.ANDROID_UNSIGNED_REQUEST_ID,source_plain_sha256:process.env.SOURCE_PLAIN_SHA256,output_public_key:process.env.OUTPUT_PUBLIC_KEY_B64}}),{mode:0o600})'
set +e
dispatch_status="$(printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" | curl --config - -sS -o dispatch-response.txt -w '%{http_code}' -X POST -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' --data-binary @dispatch.json "$api_base/actions/workflows/spin-android-unsigned.yml/dispatches")"
dispatch_curl_status=$?
set -e
[ "$dispatch_status" = 204 ] || echo "WARNING: ambiguous dispatch curl=$dispatch_curl_status HTTP=$dispatch_status; reconciling by nonce"
for attempt in $(seq 1 120); do
  github_api "$api_base/actions/workflows/spin-android-unsigned.yml/runs?event=workflow_dispatch&per_page=50" > runs.json
  node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("runs.json","utf8")),title="spin-android-unsigned-"+process.env.ANDROID_UNSIGNED_REQUEST_ID; process.stdout.write(v.workflow_runs.filter((r)=>r.display_title===title&&r.head_sha===process.env.TRUSTED_CI_REVISION&&r.event==="workflow_dispatch"&&r.path===".github/workflows/spin-android-unsigned.yml"&&r.head_repository?.full_name===process.env.TRUSTED_CI_REPOSITORY&&r.actor?.login===process.env.TRUSTED_GITHUB_MERGER).map((r)=>String(r.id)).join("\n"))' > run-ids.txt
  [ -s run-ids.txt ] && break
  sleep 5
done
test "$(grep -Ec '^[0-9]+$' run-ids.txt || true)" = 1
run_id="$(head -n 1 run-ids.txt)"

for attempt in $(seq 1 240); do
  github_api "$api_base/actions/runs/$run_id/artifacts?per_page=100" > key-artifacts.json
  node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("key-artifacts.json","utf8")),n="spin-android-source-key-"+process.env.ANDROID_UNSIGNED_REQUEST_ID,m=(v.artifacts||[]).filter((a)=>a.name===n&&!a.expired); if(m.length>1) throw new Error("duplicate source key artifact"); if(m.length===1) process.stdout.write(JSON.stringify({id:m[0].id,digest:m[0].digest||""}))' > key-artifact.json
  [ -s key-artifact.json ] && break
  sleep 5
done
key_id="$(node -p 'JSON.parse(require("fs").readFileSync("key-artifact.json","utf8")).id')"
key_digest="$(node -p 'JSON.parse(require("fs").readFileSync("key-artifact.json","utf8")).digest')"
test "${#key_digest}" = 71
printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" | curl --config - -fsSL --retry 3 "$api_base/actions/artifacts/$key_id/zip" -o key.zip
test "sha256:$(shasum -a 256 key.zip | awk '{print $1}')" = "$key_digest"
test "$(unzip -Z1 key.zip)" = source-public.pem
unzip -p key.zip source-public.pem > source-public.pem
node -e 'const crypto=require("crypto"),fs=require("fs"),k=crypto.createPublicKey(fs.readFileSync("source-public.pem")); if(k.asymmetricKeyType!=="rsa"||k.asymmetricKeyDetails?.modulusLength!==3072) throw new Error("bad worker public key")'

source_cipher="$CONTROL_DIR/$source_release_tag.tar.gz.enc"
source_key="$CONTROL_DIR/$source_release_tag.key.enc"
SOURCE_PLAIN="$source_plain" SOURCE_CIPHER="$source_cipher" SOURCE_KEY="$source_key" node -e 'const crypto=require("crypto"),fs=require("fs"),key=crypto.randomBytes(32),iv=crypto.randomBytes(12),plain=fs.readFileSync(process.env.SOURCE_PLAIN),c=crypto.createCipheriv("aes-256-gcm",key,iv),encrypted=Buffer.concat([c.update(plain),c.final()]); fs.writeFileSync(process.env.SOURCE_CIPHER,Buffer.concat([Buffer.from("SPINENC1"),iv,c.getAuthTag(),encrypted]),{mode:0o400}); fs.writeFileSync(process.env.SOURCE_KEY,crypto.publicEncrypt({key:fs.readFileSync("source-public.pem"),padding:crypto.constants.RSA_PKCS1_OAEP_PADDING,oaepHash:"sha256"},key),{mode:0o400})'
rm -f "$source_plain" source-public.pem
source_bundle="$CONTROL_DIR/$source_release_tag.handoff.zip"
(cd "$CONTROL_DIR" && zip -q -0 "$source_bundle" "$(basename "$source_cipher")" "$(basename "$source_key")")
SOURCE_RELEASE_TAG="$source_release_tag" node -e 'const fs=require("fs"); fs.writeFileSync("release.json",JSON.stringify({tag_name:process.env.SOURCE_RELEASE_TAG,target_commitish:process.env.TRUSTED_CI_REVISION,name:process.env.SOURCE_RELEASE_TAG,draft:false,prerelease:true}))'
release_status="$(printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" | curl --config - -sS -o release-response.json -w '%{http_code}' -X POST -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' --data-binary @release.json "$api_base/releases")"
test "$release_status" = 201
source_release_id="$(node -p 'JSON.parse(require("fs").readFileSync("release-response.json","utf8")).id')"
source_asset_name="$source_release_tag.handoff.zip"
upload_status="$(printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" | curl --config - -sS -o upload-response.json -w '%{http_code}' -X POST -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/zip' --data-binary @"$source_bundle" "https://uploads.github.com/repos/$TRUSTED_CI_REPOSITORY/releases/$source_release_id/assets?name=$source_asset_name")"
test "$upload_status" = 201

for attempt in $(seq 1 1440); do
  github_api "$api_base/actions/runs/$run_id" > run.json
  if [ "$(node -p 'JSON.parse(require("fs").readFileSync("run.json","utf8")).status')" = completed ]; then
    run_completed='true'
    break
  fi
  sleep 5
done
test "$(node -p 'JSON.parse(require("fs").readFileSync("run.json","utf8")).conclusion')" = success
github_api "$api_base/actions/runs/$run_id/artifacts?per_page=100" > artifacts.json
node -e 'const fs=require("fs"),v=JSON.parse(fs.readFileSync("artifacts.json","utf8")),out="spin-unsigned-android-"+process.env.ANDROID_UNSIGNED_REQUEST_ID,key="spin-android-source-key-"+process.env.ANDROID_UNSIGNED_REQUEST_ID,live=(v.artifacts||[]).filter((a)=>!a.expired),m=live.filter((a)=>a.name===out); if(v.total_count!==2||live.length!==2||m.length!==1||live.filter((a)=>a.name===key).length!==1||!/^sha256:[0-9a-f]{64}$/.test(m[0].digest||"")) throw new Error("unexpected artifact set"); fs.writeFileSync("artifact-record.json",JSON.stringify({id:m[0].id,digest:m[0].digest}))'
artifact_id="$(node -p 'JSON.parse(require("fs").readFileSync("artifact-record.json","utf8")).id')"
artifact_digest="$(node -p 'JSON.parse(require("fs").readFileSync("artifact-record.json","utf8")).digest')"
printf 'user = "%s:%s"\n' "$GITHUB_API_USER" "$GITHUB_API_TOKEN" | curl --config - -fsSL --retry 3 "$api_base/actions/artifacts/$artifact_id/zip" -o output-artifact.zip
test "sha256:$(shasum -a 256 output-artifact.zip | awk '{print $1}')" = "$artifact_digest"
test "$(unzip -Z1 output-artifact.zip | LC_ALL=C sort)" = "$(printf '%s\n' android-output.key.enc android-output.zip.enc | LC_ALL=C sort)"
unzip -p output-artifact.zip android-output.zip.enc > android-output.zip.enc
unzip -p output-artifact.zip android-output.key.enc > android-output.key.enc
node -e 'const crypto=require("crypto"),fs=require("fs"),p=fs.readFileSync("android-output.zip.enc"); if(p.subarray(0,8).toString()!=="SPINENC1"||p.length<36) throw new Error("bad output envelope"); const key=crypto.privateDecrypt({key:fs.readFileSync(process.env.OUTPUT_PRIVATE_KEY),padding:crypto.constants.RSA_PKCS1_OAEP_PADDING,oaepHash:"sha256"},fs.readFileSync("android-output.key.enc")); if(key.length!==32) throw new Error("bad output key"); const d=crypto.createDecipheriv("aes-256-gcm",key,p.subarray(8,20)); d.setAuthTag(p.subarray(20,36)); fs.writeFileSync("android-output.zip",Buffer.concat([d.update(p.subarray(36)),d.final()]),{mode:0o400})'
test "$(unzip -Z1 android-output.zip | LC_ALL=C sort)" = "$(printf '%s\n' artifact-metadata.json unsigned.aab unsigned.aab.sha256 unsigned.apk unsigned.apk.sha256 | LC_ALL=C sort)"
rm -rf "$SOURCE_CHECKOUT/handoff"
mkdir -m 700 "$SOURCE_CHECKOUT/handoff"
unzip -q android-output.zip -d "$SOURCE_CHECKOUT/handoff"
(cd "$SOURCE_CHECKOUT/handoff" && shasum -a 256 -c unsigned.aab.sha256 && shasum -a 256 -c unsigned.apk.sha256)
METADATA="$SOURCE_CHECKOUT/handoff/artifact-metadata.json" node -e 'const fs=require("fs"),m=JSON.parse(fs.readFileSync(process.env.METADATA,"utf8")); if(m.worker!=="github-hosted"||m.credentialFree!==true||m.commit!==process.env.BUILD_COMMIT||String(m.versionCode)!==process.env.BUILD_NUMBER||m.versionName!==process.env.SPIN_VERSION_NAME) throw new Error("Android handoff metadata mismatch")'
chmod 500 "$SOURCE_CHECKOUT/handoff"
chmod 400 "$SOURCE_CHECKOUT/handoff"/*

