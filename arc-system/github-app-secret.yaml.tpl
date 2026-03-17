# GitHub App credentials secret for ARC
# DO NOT commit real values — this file is a template only.
# install.sh creates this secret from environment variables.
apiVersion: v1
kind: Secret
metadata:
  name: arc-github-app-secret
  namespace: arc-system
type: Opaque
stringData:
  github_app_id: "<GITHUB_APP_ID>"
  github_app_installation_id: "<GITHUB_APP_INSTALLATION_ID>"
  github_app_private_key: |
    <GITHUB_APP_PRIVATE_KEY_PEM>
