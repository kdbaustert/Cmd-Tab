import { open, showHUD } from '@raycast/api'

export default async function ShowAllWindows() {
  await open('cmdtab://windows/showAll')
  await showHUD('Showed all windows')
}
