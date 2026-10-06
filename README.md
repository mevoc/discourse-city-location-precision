# discourse-city-location-precision

Enforcement point for **PRD §4.5, decision D8**. Not a feature.

## What it does

Every topic location written through `discourse-locations` passes through one method,
`Locations::TopicLocationStore.assign`, which updates both the canonical
`topic.custom_fields["location"]` and the `locations_topic` projection. This plugin prepends
that method and, before the value is stored:

1. **Rounds the coordinate** to `city_location_coordinate_decimals` (default 3 — about 110 m
   north–south and 62 m east–west at Helsingborg's latitude). The setting's maximum is 3,
   because §4.5's grid may only go coarser; a higher bound would be an off switch.
2. **Keeps only `lat` and `lon`** inside `geo_location`, and strips the reverse-geocoded
   components from the top level too. This is an allowlist rather than a list of known-bad
   keys, so a column a future geocoder or schema adds is excluded by default.
3. **Keeps `name`** — the one input in discourse-locations' add-location modal that a resident
   types themselves, and where the portal's free-text location detail lives. It is kept *only*
   while `location_geocoding` is `none`; with geocoding on, `name` may be geocoder output, so
   it is suppressed as well. `raw` is always suppressed: discourse-locations fills it from the
   geocoder's address, so it is never resident input.

Because the hook sits at the store rather than in the wizard, it covers **every write path that
goes through `TopicLocationStore.assign`** — which today is the submission wizard, the raw REST
API and anything else reaching the model, verified against a live instance with a direct API
POST. That phrasing is deliberate: it is the admissibility condition PRD §4.2 places on any
alternative capture path, and it is narrower than "every write path".

For the paths that do *not* go through the store — a rake task, an import, a projection rebuild,
a direct model write — a `before_save` on `Locations::TopicLocation` coarsens and clears there
too. Neither hook depends on the other.

## Why there is no on/off setting

The PRD treats the precision boundary as an invariant, not a preference. A resident publishes
their full name on every submission (§4.1), so a metre-accurate pin — especially one captured by
a "use my current location" tap made at home — would publish where a named person lives. The
client rounds for display honesty; this is the boundary that cannot be bypassed, so it is not
switchable from the admin UI.

The grid itself *is* configurable, because it is a per-instance bundle parameter (§4.4): three
decimals resolves a block in a city and frequently a single property in a village or a rural
region, where a sparser instance sets a coarser grid.

## What it does not do

It does not disable geocoding. That is a `discourse-locations` site setting
(`location_geocoding: none`) and a bundle parameter. This plugin strips the address components
anyway, so the *stored* columns do not depend on that setting staying correct — **but the
off-host flow does**. With geocoding left at its default, the full-precision coordinate is sent
to Nominatim before this hook ever runs. PRD §4.6's "sent to third parties: nothing" rests on
the site setting, not on this plugin.

It removes two Geocoder callbacks from `Locations::TopicLocation`. The model declares
`geocoded_by`/`reverse_geocoded_by` with `after_validation` hooks, which fire on save and do
*not* respect `location_geocoding: none` — that setting governs a different code path. Left in
place they would send a coordinate off-host on every row save, and then try to write the result
back into the columns §4.5 requires empty. (They also break direct model writes outright:
`reverse_geocode` assigns to `address=`, which the model defines as a reader only.)

It does not coarsen the coordinate in transit. §4.5 puts the boundary server-side by design, so
a full-precision pin exists in request parameters and may appear in an error trace. "Never
reaches the database" holds; "never reaches the host" was never the claim.

It does not round *user profile* locations, because the PRD turns that feature off entirely
(§4.5). If profile locations were ever enabled, this plugin would need extending to
`UserLocationStore`.

## Existing rows

The hooks hold from installation onward. `rake city_location_precision:recoarsen` re-coarsens
what was stored before that, or while the grid was set finer — an imported archive, a restored
backup, or an instance that ran unenforced.

## Tests

`spec/lib/city_location_precision_spec.rb` encodes the two acceptance criteria stated in §4.5
verbatim. Run inside the container:

```
docker exec -u discourse app bash -c \
  'cd /var/www/discourse && LOAD_PLUGINS=1 bundle exec rspec \
   plugins/discourse-city-location-precision/spec'
```
