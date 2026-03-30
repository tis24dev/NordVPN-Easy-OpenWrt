#!/bin/sh

nordvpn_easy_build_server_catalog_json() {
	local country_id="$1"
	local country_code="$2"
	local country_name="$3"

	jq -ce \
		--argjson country_id "$country_id" \
		--arg country_code "$country_code" \
		--arg country_name "$country_name" '
			{
				country_id: $country_id,
				country_code: $country_code,
				country_name: $country_name,
				servers: [
					.[] | {
						hostname: (.hostname // ""),
						station: (.station // ""),
						load: (.load // 0),
						city: (.locations[0].country.city.name // ""),
						country_code: (.locations[0].country.code // $country_code),
						country_name: (.locations[0].country.name // $country_name),
						public_key: ([.technologies[]? | select(.identifier == "wireguard_udp") | .metadata[]? | select(.name == "public_key") | .value][0] // ""),
						status: (.status // "")
					} | select(
						(.hostname != "") and
						(.station != "") and
						(.public_key != "") and
						(.status != "offline")
					)
				] | sort_by(.load, (.city | ascii_downcase), (.hostname | ascii_downcase))
			}
		'
}

nordvpn_easy_server_catalog_has_servers() {
	jq -er '.servers[0].station // empty' "$1" >/dev/null 2>&1
}

nordvpn_easy_server_catalog_candidates_tsv() {
	jq -r '.servers[] | [
		.hostname,
		.station,
		.public_key,
		.country_code,
		.city,
		((.load // 0) | tostring)
	] | @tsv' "$1" 2>/dev/null
}

nordvpn_easy_recommendation_candidates_tsv() {
	jq -r '.[] | [
		.hostname,
		.station,
		([.technologies[]?.metadata[]? | select(.name=="public_key").value][0]),
		(.locations[0].country.code // ""),
		(.locations[0].country.city.name // ""),
		((.load // 0) | tostring)
	] | @tsv' "$1" 2>/dev/null
}

nordvpn_easy_emit_server_catalog_json() {
	local catalog_file="$1"
	local ts_file="$2"
	local cache_ttl="${3:-86400}"
	local cached_at=''

	cached_at="$(cat "$ts_file" 2>/dev/null || true)"

	jq -ce \
		--arg cached_at "$cached_at" \
		--arg cache_ttl "$cache_ttl" '
			. + {
				cached_at: ($cached_at | tonumber? // null),
				cache_ttl: ($cache_ttl | tonumber? // 86400)
			}
		' "$catalog_file"
}
