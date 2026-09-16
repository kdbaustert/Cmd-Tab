import arrangementsJson from '../../arrangements.json'

// The single source of truth for every `cmdtab://tile/<raw>` argument lives one
// directory up, in `integrations/arrangements.json`, so this file and the Alfred
// workflow's `tile.sh` read the same list instead of carrying their own copies.
// Adding an arrangement — or the `restore`/`layout` verbs mentioned in the repo's
// README — is one edit there, not one per integration.

export interface Arrangement {
  raw: string
  title: string
  family: string
}

export const arrangements: Arrangement[] = arrangementsJson
