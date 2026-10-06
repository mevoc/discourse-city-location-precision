# frozen_string_literal: true
# name: discourse-city-location-precision
# about: Enforces the coordinate-precision invariant of the City Improvements PRD, section 4.5, decision D8
# version: 0.1.0
# authors: City Improvements
# url: https://github.com/mevoc/discourse-city-location-precision

module ::CityLocationPrecision
  PLUGIN_NAME = "discourse-city-location-precision"

  # This is an enforcement point, not a feature — see README.md.

  # An ALLOWLIST, not a denylist. discourse-locations' projection carries nine address
  # columns and a future geocoder or schema could add more; anything not named here is
  # dropped, so a new field is excluded by default rather than persisted by default.
  PERMITTED_GEO_KEYS = %w[lat lon].freeze

  # The projection reads payload[key] before geo_location[key], so the top level has to be
  # cleared of the same components.
  #
  # `name` is NOT here: it is the one input in discourse-locations' add-location modal that a
  # resident types themselves (rendered unconditionally, outside `location_input_fields`), and
  # it is where PRD §4.5's free-text location detail lives. `raw` is not resident input either
  # way — discourse-locations sets it from the geocoder's `address` — so it is suppressed.
  SUPPRESSED_PAYLOAD_KEYS = %w[
    raw street district city state postalcode country countrycode
    international_code locationtype boundingbox
  ].freeze

  # `name` is only safe to keep while nothing can auto-populate it. With geocoding enabled it
  # may hold geocoder output, so it is suppressed too — the resident's own text is preserved
  # exactly when it can only be the resident's own text.
  def self.geocoding_disabled?
    SiteSetting.location_geocoding.to_s == "none"
  rescue StandardError
    false
  end

  def self.suppressed_keys
    geocoding_disabled? ? SUPPRESSED_PAYLOAD_KEYS : SUPPRESSED_PAYLOAD_KEYS + %w[name]
  end

  def self.decimals
    SiteSetting.city_location_coordinate_decimals
  end

  # Coarsens a coordinate to the configured grid.
  #
  # Uses #to_f rather than Kernel#Float on purpose: the projection column is numeric, so
  # the store coerces with #to_f regardless. Float("56.046467x") raises and would leave the
  # original string in place, which #to_f would then widen back to full precision downstream.
  # Matching the store's own coercion closes that path.
  def self.round_coordinate(value)
    return value if value.nil?
    return value if value.is_a?(String) && value.strip.empty?

    value.to_f.round(decimals)
  end

  def self.apply(location)
    # A payload that does not parse is passed through untouched: discourse-locations'
    # `assign` parses it identically, gets nil, and deletes the row rather than storing
    # anything. There is no path here that persists an unparsed coordinate.
    payload = ::Locations::Payload.parse(location)
    return location if payload.blank?

    suppressed_keys.each { |key| payload.delete(key) }

    geo = payload["geo_location"]
    if geo.is_a?(Hash)
      geo.keep_if { |key, _| PERMITTED_GEO_KEYS.include?(key) }
      PERMITTED_GEO_KEYS.each { |key| geo[key] = round_coordinate(geo[key]) if geo.key?(key) }
    end

    payload
  end

  module TopicLocationStoreExtension
    def assign(topic:, location:)
      super(topic: topic, location: ::CityLocationPrecision.apply(location))
    end
  end

  # Defence in depth, as a mixin rather than a class_eval so the Discourse
  # NoMonkeyPatching cop is satisfied: the store prepend covers writes through
  # TopicLocationStore.assign, but the invariant is about what is *persisted*. A rake task,
  # an import, a projection rebuild or a direct model write would bypass it. This cannot.
  module TopicLocationExtension
    extend ActiveSupport::Concern

    included { before_save :enforce_city_location_precision }

    private

    def enforce_city_location_precision
      self.latitude = ::CityLocationPrecision.round_coordinate(latitude)
      self.longitude = ::CityLocationPrecision.round_coordinate(longitude)
      ::CityLocationPrecision.suppressed_keys.each do |column|
        self[column] = nil if has_attribute?(column)
      end
    end
  end
end

after_initialize do
  # Fail closed. This plugin exists to make a privacy guarantee unbypassable; an instance
  # that boots without it, serving discourse-locations unenforced, is the failure this
  # guards against. A log line would let that happen quietly.
  if !defined?(::Locations::TopicLocationStore)
    raise <<~MSG
      [#{::CityLocationPrecision::PLUGIN_NAME}] discourse-locations is not loaded.
      This plugin enforces the coordinate-precision boundary of PRD section 4.5 (D8) and
      cannot do so without it. Refusing to boot rather than serving locations unenforced.
    MSG
  end

  ::Locations::TopicLocationStore.singleton_class.prepend(
    ::CityLocationPrecision::TopicLocationStoreExtension,
  )

  # Locations::TopicLocation declares `geocoded_by :address` / `reverse_geocoded_by
  # :latitude, :longitude` with `after_validation :geocode` and `:reverse_geocode`. Those are
  # live outbound calls on the model, fired on save — they do NOT respect the plugin's
  # `location_geocoding: none` site setting, which governs a different code path. Left alone,
  # saving a row would send a resident's coordinate off-host (PRD §4.6) and then try to write
  # the result back into address columns §4.5 requires empty. Removing them closes both.
  #
  # It also un-breaks direct model writes: `reverse_geocode` assigns to `address=`, which the
  # model defines as a reader only, so any direct create raises before reaching the hook below.
  %i[geocode reverse_geocode].each do |callback|
    ::Locations::TopicLocation.skip_callback(:validation, :after, callback, raise: false)
  end

  ::Locations::TopicLocation.include(::CityLocationPrecision::TopicLocationExtension)
end
