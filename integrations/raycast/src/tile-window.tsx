import { List, ActionPanel, Action, open, showHUD } from '@raycast/api'
import { arrangements } from './arrangements'

async function tile(raw: string, title: string) {
  await open(`cmdtab://tile/${raw}`)
  await showHUD(title)
}

export default function TileWindow() {
  return (
    <List searchBarPlaceholder="Search window arrangements">
      {arrangements.map(a => (
        <List.Item
          key={a.raw}
          title={a.title}
          subtitle={a.family}
          actions={
            <ActionPanel>
              <Action
                title="Apply Arrangement"
                onAction={() => tile(a.raw, a.title)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  )
}
