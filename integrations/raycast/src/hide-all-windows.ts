import { open, showHUD } from '@raycast/api'

export default async function HideAllWindows() {
  await open('cmdtab://windows/hideAll')
  await showHUD('Hid all windows')
}
