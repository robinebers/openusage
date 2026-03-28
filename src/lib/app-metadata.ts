export const APP_NAME = "UsageTray"
export const REPO_OWNER = "Rana-Faraz"
export const REPO_NAME = "usage-tray-windows"

export const REPO_URL = `https://github.com/${REPO_OWNER}/${REPO_NAME}`
export const REPO_ISSUES_URL = `${REPO_URL}/issues`
export const REPO_RELEASES_URL = `${REPO_URL}/releases`
export const REPO_API_RELEASES_BASE_URL = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases`

export function repoPullUrl(number: string) {
  return `${REPO_URL}/pull/${number}`
}

export function repoCommitUrl(sha: string) {
  return `${REPO_URL}/commit/${sha}`
}

export function releaseTagUrl(tag: string) {
  return `${REPO_RELEASES_URL}/tag/${tag}`
}
