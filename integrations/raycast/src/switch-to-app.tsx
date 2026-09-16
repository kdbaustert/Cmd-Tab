import {
  List,
  ActionPanel,
  Action,
  open,
  getApplications,
  Application,
} from '@raycast/api'
import { useEffect, useState } from 'react'

export default function SwitchToApp() {
  const [apps, setApps] = useState<Application[]>([])
  const [isLoading, setIsLoading] = useState(true)

  useEffect(() => {
    getApplications()
      .then(setApps)
      .finally(() => setIsLoading(false))
  }, [])

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search apps">
      {apps.map(app => (
        <List.Item
          key={app.bundleId ?? app.path}
          title={app.name}
          icon={{ fileIcon: app.path }}
          actions={
            <ActionPanel>
              <Action
                title="Activate through Cmd-Tab"
                onAction={() => {
                  if (app.bundleId) open(`cmdtab://activate/${app.bundleId}`)
                }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  )
}
