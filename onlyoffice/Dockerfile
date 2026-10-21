# The appliance's OnlyOffice Document Server: the upstream image, minus the
# AI plugin it ships (decision of 2026-10-19 — the assistant in the editor is
# Suite 366's own plugin, served by the app and added per document through
# editorConfig.plugins).
#
# The upstream plugins are NOT in the image: run-document-server.sh installs
# them at every start (PLUGINS_ENABLED, default true) from the marketplace
# list below, into sdkjs-plugins/, which is not on the PVC. Deleting the
# plugin's directory by hand would come back at the next pod start; taking
# "ai" out of the list is what keeps it out. The other plugins stay.
#
# Published by .github/workflows/publish-onlyoffice-image.yml as
# ghcr.io/scriptor-group/suite-366-onlyoffice:<base tag>-s<SUITE366_REV>.
# The tag is immutable: bump SUITE366_REV to publish a change, then pin the
# new tag in values.yaml AND update.sh (ONLYOFFICE_IMAGE) together.
ARG BASE_IMAGE=onlyoffice/documentserver:9.4.0
FROM ${BASE_IMAGE}

ARG SUITE366_REV=1
LABEL suite366.onlyoffice="${SUITE366_REV}" \
      org.opencontainers.image.source="https://github.com/Scriptor-Group/suite366-deploy"

RUN python3 - <<'PY'
import json
path = "/var/www/onlyoffice/documentserver/sdkjs-plugins/plugin-list-default.json"
plugins = json.load(open(path))
assert "ai" in plugins, "no 'ai' in %s: %r -- the upstream list changed, review this Dockerfile" % (path, plugins)
with open(path, "w") as f:
    json.dump([p for p in plugins if p != "ai"], f, indent="\t")
    f.write("\n")
PY
