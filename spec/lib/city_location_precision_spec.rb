# frozen_string_literal: true

require "rails_helper"

# These tests encode the acceptance criteria of PRD §4.5 (decision D8):
#
#   "Acceptance criterion: a direct API POST carrying six decimal places is stored with three"
#   "Acceptance criterion: after submitting with a pin, locations_topic shows street,
#    postalcode, city, district, name and boundingbox null for that row"
#
describe CityLocationPrecision do
  let(:fine) { { "geo_location" => { "lat" => "56.046467", "lon" => "12.694512" } } }

  describe ".apply" do
    it "rounds coordinates to the configured grid (§4.5)" do
      result = described_class.apply(fine)

      expect(result["geo_location"]["lat"]).to eq(56.046)
      expect(result["geo_location"]["lon"]).to eq(12.695)
    end

    it "honours the per-instance grid parameter (§4.4)" do
      SiteSetting.city_location_coordinate_decimals = 2

      result = described_class.apply(fine)

      expect(result["geo_location"]["lat"]).to eq(56.05)
      expect(result["geo_location"]["lon"]).to eq(12.69)
    end

    it "accepts a JSON string payload, as the raw API sends" do
      result = described_class.apply(fine.to_json)

      expect(result["geo_location"]["lat"]).to eq(56.046)
    end

    it "keeps only lat and lon inside geo_location, so a new column is excluded by default" do
      payload = {
        "geo_location" => {
          "lat" => "56.046467",
          "lon" => "12.694512",
          "house_number" => "15",
          "suburb" => "Norr",
        },
      }

      result = described_class.apply(payload)

      expect(result["geo_location"].keys).to contain_exactly("lat", "lon")
    end

    it "coarsens a coordinate the store would otherwise widen back via to_f" do
      # Kernel#Float raises on this; String#to_f does not. The projection column is numeric,
      # so the store coerces with to_f — matching that coercion is what closes the path.
      result = described_class.apply({ "geo_location" => { "lat" => "56.046467x" } })

      expect(result["geo_location"]["lat"]).to eq(56.046)
    end

    it "strips geocoded address components at both payload levels (§4.5)" do
      payload = {
        "street" => "Drottninggatan 15",
        "geo_location" => {
          "lat" => "56.046467",
          "lon" => "12.694512",
          "street" => "Drottninggatan 15",
          "postalcode" => "252 21",
          "city" => "Helsingborg",
          "district" => "Centrum",
          "name" => "Drottninggatan 15",
          "boundingbox" => %w[56.04 56.05 12.69 12.70],
        },
      }

      result = described_class.apply(payload)

      described_class::SUPPRESSED_PAYLOAD_KEYS.each { |key| expect(result).not_to have_key(key) }
      expect(result["geo_location"].keys).to contain_exactly("lat", "lon")
    end

    it "leaves the resident's own free-text detail alone (§4.5)" do
      payload = fine.merge("raw" => "Utanför Drottninggatan 15, vid busshållplatsen")

      result = described_class.apply(payload)

      expect(result["raw"]).to eq("Utanför Drottninggatan 15, vid busshållplatsen")
    end

    it "passes through a payload with no coordinates" do
      expect(described_class.apply(nil)).to be_nil
      expect(described_class.apply({})).to eq({})
    end

    it "does not raise on a non-numeric coordinate" do
      result = described_class.apply({ "geo_location" => { "lat" => "nowhere", "lon" => nil } })

      # to_f gives 0.0, which is what the numeric column would have stored anyway.
      expect(result["geo_location"]["lat"]).to eq(0.0)
    end
  end

  describe "enforcement at the store boundary" do
    it "is prepended to the one method that writes both stores (§4.5)" do
      ancestors = Locations::TopicLocationStore.singleton_class.ancestors

      expect(ancestors).to include(CityLocationPrecision::TopicLocationStoreExtension)
    end

    it "persists a coarse coordinate and no address, whatever the caller sends" do
      topic = Fabricate(:topic)

      Locations::TopicLocationStore.assign(
        topic: topic,
        location: {
          "geo_location" => {
            "lat" => "56.046467",
            "lon" => "12.694512",
            "street" => "Drottninggatan 15",
            "postalcode" => "252 21",
          },
        },
      )

      row = Locations::TopicLocation.find_by(topic_id: topic.id)

      expect(row.latitude).to eq(56.046)
      expect(row.longitude).to eq(12.695)
      expect(row.street).to be_nil
      expect(row.postalcode).to be_nil
    end

    it "coarsens the canonical custom field too, not only the projection (§4.5)" do
      topic = Fabricate(:topic)

      Locations::TopicLocationStore.assign(
        topic: topic,
        location: { "geo_location" => { "lat" => "56.046467", "lon" => "12.694512" } },
      )

      stored = Locations::TopicLocationStore.fetch(topic.reload)

      expect(stored["geo_location"]["lat"]).to eq(56.046)
      expect(stored["geo_location"]["lon"]).to eq(12.695)
    end

    it "coarsens a direct model write, which never touches the store (§4.5)" do
      topic = Fabricate(:topic)

      row =
        Locations::TopicLocation.create!(
          topic_id: topic.id,
          latitude: 56.046467,
          longitude: 12.694512,
          street: "Drottninggatan 15",
        )

      expect(row.reload.latitude).to eq(56.046)
      expect(row.reload.street).to be_nil
    end
  end

  describe "the grid parameter" do
    it "cannot be raised above the three decimals PRD §4.5 states as the maximum" do
      expect { SiteSetting.city_location_coordinate_decimals = 6 }.to raise_error(
        Discourse::InvalidParameters,
      )
    end

    it "can still be made coarser for a sparser instance (§4.4)" do
      expect { SiteSetting.city_location_coordinate_decimals = 2 }.not_to raise_error
    end
  end

  describe "the model's own geocoder callbacks" do
    it "no longer fires reverse geocoding on save (§4.6)" do
      callbacks = Locations::TopicLocation._validation_callbacks.map(&:filter)

      expect(callbacks).not_to include(:geocode)
      expect(callbacks).not_to include(:reverse_geocode)
    end
  end
end
