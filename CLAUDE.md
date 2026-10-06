# discourse-city-location-precision

A Discourse plugin that is **one enforcement point, not a feature**. It exists so that the
coordinate-precision guarantee of the City Improvements portal cannot be bypassed.

The product context lives in **`mevoc/city-improvements`** (private) — its `CLAUDE.md` and
`docs/city-improvements-portal-prd.md` §4.1, §4.5 and §4.6 are required reading before
changing anything here. This repo holds no product decisions.

If you are reading this from outside that project: the portal is a civic discussion platform
where every submission carries the author's real name, which is why a coarse coordinate is a
hard requirement rather than a setting. The rules below are the whole point of the plugin.

---

## The invariant

PRD §4.5, decision **D8**: *no coordinate is persisted anywhere at finer than the configured
grid*, and the reverse-geocoded address columns stay empty.

It matters because every submission displays the resident's real full name (§4.1). A name plus
a metre-accurate pin — especially one captured by a "use my current location" tap made at home
— publishes where a named person lives. Coarsening the coordinate is what makes mandatory real
names and optional pins safe to have at the same time.

## Hard rules

- **No on/off site setting.** The grid may only go *coarser*; `max: 3` in `config/settings.yml`
  is the PRD's floor, not a default. A higher bound would be an off switch for the guarantee.
- **Fail closed.** Missing `discourse-locations` raises at boot. An instance that serves
  locations unenforced is the failure this guards against; a log line would let it pass.
- **`PERMITTED_GEO_KEYS` is an allowlist.** A column a future geocoder or schema adds must be
  excluded by default, never persisted by default.
- **Two hooks, independent.** The store prepend covers writes through
  `TopicLocationStore.assign`; the `before_save` on `Locations::TopicLocation` covers rake
  tasks, imports, projection rebuilds and direct model writes. Neither relies on the other.
- **The model's geocoder callbacks stay removed.** `geocoded_by` / `reverse_geocoded_by` fire
  on save and do *not* respect `location_geocoding: none`. Re-enabling them sends resident
  coordinates off-host.

## Upstream coupling

The store prepend targets `Locations::TopicLocationStore.assign` in
[`discourse-locations`](https://github.com/paviliondev/discourse-locations). If upstream moves
that write path, this plugin silently stops covering it — which is why `app.yml` in
`city-improvements` **pins** a commit while CI tests the branch tip. A red CI build on an
upstream change is the warning; treat it as one, not as a lint failure.

## Tests

`spec/lib/city_location_precision_spec.rb` encodes PRD §4.5's acceptance criteria verbatim.
CI (`.github/workflows/ci.yml`) uses Discourse's reusable plugin pipeline and clones
`discourse-locations` from `about.json`'s `tests.requiredPlugins`, without which the spec
cannot boot.

A change here that weakens any rule above is significant by definition: it touches the privacy
invariant, so it goes to André as a PR with a `privacy-reviewer` pass.
