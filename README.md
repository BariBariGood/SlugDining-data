# SlugDining-data

Live location/hours feed for the [SlugDining](https://github.com/BariBariGood/SlugDining)
app. Replaces the retired Vercel JSON endpoints.

The app fetches these files at cold start via raw.githubusercontent.com and
falls back to its bundled copies if unreachable:

```
https://raw.githubusercontent.com/BariBariGood/SlugDining-data/main/data/dining_options.json
https://raw.githubusercontent.com/BariBariGood/SlugDining-data/main/data/gym_options.json
```

## How data is maintained

`data/*.json` files are the registry **and** the artifact. Hand-maintained
fields (titles, FoodPro ids, routes, notices) live in the same file as the
machine-maintained `hours` + `verified` fields. Each entry's `source` URL
tells the scraper which UCSC page to re-derive hours from.

`.github/workflows/refresh.yml` runs the scraper every Monday and commits any
diff. To add/rename/remove a location, edit the JSON and run
`dart run tool/scrape.dart` — or let the weekly run pick it up.

## dining_options.json schema

| field | notes |
|---|---|
| `title` | display name; groups into Dining Halls / Cafés / Markets tabs by `type` |
| `type` | `dining-hall` \| `cafe` \| `market` |
| `route` | in-app menu route; omit ⇒ card isn't navigable |
| `foodProId` | nutrition.sa.ucsc.edu `locationNum` for menu fetches |
| `menuTitle` | menu-page AppBar text |
| `menuTabs` | meal names in display order (`Breakfast`, `Lunch`, `Dinner`, `Late Night`, `Menu`, `All Day`, `ALL`, …) |
| `menuExcludeAllDay` | hide FoodPro's "All Day" category (false for Oakes/Owl's) |
| `autoAdvanceAtHour` | hour-of-day after which the menu page defaults to tomorrow |
| `statusName` | exact location name for the dining.ucsc.edu open/closed plugin; omit ⇒ no live status |
| `notice` | short line shown under the card title (payment rules, closures) |
| `externalUrl` | launched on tap when no `route` |
| `hours` | `mon`–`sun` → list of `{open, close}` fractional-hour windows; `[]` = closed |
| `source` | page the scraper re-derives `hours` from |
| `verified` | last successful scrape date (UTC) |

## gym_options.json schema

`title`, `tags`, `hours` (same shape), `source` (Campus Rec `GetFacility`
URL), `verified`. Entries with no Campus Rec page carry `note` instead of
`source` and keep hand-maintained hours.
