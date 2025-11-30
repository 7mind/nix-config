#!/usr/bin/env python3
"""
NordVPN WireGuard Configuration Extractor
Extracts WireGuard configuration files from NordVPN's API.
Uses only Python standard library (no external dependencies).
"""

import argparse
import base64
import json
import os
import sys
from typing import Optional
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from urllib.error import URLError, HTTPError


class NordVPNConfigExtractor:
    """Handles extraction of NordVPN WireGuard configurations."""

    CREDENTIALS_URL = "https://api.nordvpn.com/v1/users/services/credentials"
    SERVER_RECOMMENDATIONS_URL = "https://api.nordvpn.com/v1/servers/recommendations"
    COUNTRIES_URL = "https://api.nordvpn.com/v1/servers/countries"
    DEFAULT_DNS = "194.242.2.4, 94.140.14.14"

    def __init__(self, access_token: str):
        """Initialize with access token."""
        self.access_token = access_token
        self._country_map = None

    def _make_request(self, url: str, auth: bool = False) -> dict:
        """
        Make HTTP GET request using urllib.

        Args:
            url: URL to request
            auth: Whether to include basic authentication

        Returns:
            Parsed JSON response
        """
        try:
            request = Request(url)
            # Add basic authentication if needed
            if auth:
                credentials = base64.b64encode(
                    f"token:{self.access_token}".encode()
                ).decode()
                request.add_header("Authorization", f"Basic {credentials}")

            with urlopen(request) as response:
                data = response.read().decode('utf-8')
                return json.loads(data)
        except HTTPError as e:
            print(f"HTTP Error {e.code}: {e.reason}", file=sys.stderr)
            sys.exit(1)
        except URLError as e:
            print(f"URL Error: {e.reason}", file=sys.stderr)
            sys.exit(1)
        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}", file=sys.stderr)
            sys.exit(1)

    def get_private_key(self) -> str:
        """Retrieve NordLynx private key from API."""
        try:
            data = self._make_request(self.CREDENTIALS_URL, auth=True)
            return data["nordlynx_private_key"]
        except KeyError:
            print("Error: Could not find nordlynx_private_key in response", file=sys.stderr)
            sys.exit(1)

    def _get_country_id(self, country_code: str) -> Optional[int]:
        """
        Get numeric country ID from country code.

        Args:
            country_code: 2-letter country code (e.g., 'us', 'nl', 'uk')

        Returns:
            Numeric country ID or None if not found
        """
        # Lazy load country map
        if self._country_map is None:
            try:
                countries = self._make_request(self.COUNTRIES_URL, auth=False)
                self._country_map = {
                    country["code"].lower(): country["id"] for country in countries
                }
            except Exception as e:
                print(f"Error fetching country list: {e}", file=sys.stderr)
                return None
        return self._country_map.get(country_code.lower())

    def get_server_recommendations(
        self,
        limit: int,
        country: Optional[str] = None
    ) -> list:
        """
        Get server recommendations from NordVPN API.

        Args:
            limit: Number of servers to retrieve
            country: Optional country code to filter by (e.g., 'us', 'uk', 'de')
        """
        params = {
            "filters[servers_technologies][identifier]": "wireguard_udp",
            "limit": str(limit)
        }
        if country:
            country_id = self._get_country_id(country)
            if country_id is None:
                print(f"Warning: Country code '{country}' not found. Getting recommendations without country filter.", file=sys.stderr)
            else:
                params["filters[country_id]"] = str(country_id)

        # Build URL with query parameters
        url = f"{self.SERVER_RECOMMENDATIONS_URL}?{urlencode(params)}"
        return self._make_request(url, auth=False)

    def create_config(
        self,
        server: dict,
        private_key: str,
        dns: str = DEFAULT_DNS
    ) -> tuple[str, str]:
        """
        Create WireGuard configuration from server data.

        Returns:
            Tuple of (filename, config_content)
        """
        # Extract server information
        country_name = server["locations"][0]["country"]["name"]
        city_name = server["locations"][0]["country"]["city"]["name"]
        hostname = server["hostname"]
        station_ip = server["station"]

        # Find WireGuard public key
        public_key = None
        for tech in server["technologies"]:
            if tech["identifier"] == "wireguard_udp":
                for metadata in tech["metadata"]:
                    public_key = metadata["value"]
                    break
                break

        if not public_key:
            raise ValueError(f"No WireGuard public key found for {hostname}")

        # Create filename
        filename = f"{country_name} - {city_name} - {hostname}.conf"

        # Create config content
        config = f"""# {filename}
[Interface]
PrivateKey = {private_key}
Address = 10.5.0.2/32
DNS = {dns}

[Peer]
PublicKey = {public_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {station_ip}:51820
"""
        return filename, config

    def list_countries(self):
        """List all available countries with their codes."""
        try:
            countries = self._make_request(self.COUNTRIES_URL, auth=False)
            print("Available countries:")
            print("-" * 40)
            # Sort by country name
            sorted_countries = sorted(countries, key=lambda x: x["name"])
            for country in sorted_countries:
                print(f"{country['code']:3s} - {country['name']}")
        except Exception as e:
            print(f"Error fetching country list: {e}", file=sys.stderr)
            sys.exit(1)

    def extract_configs(
        self,
        total_configs: int = 3,
        country: Optional[str] = None,
        dns: str = DEFAULT_DNS,
        output_dir: str = "."
    ):
        """
        Extract WireGuard configurations and save to files.

        Args:
            total_configs: Number of configurations to extract
            country: Optional country code to filter by
            dns: DNS servers to use
            output_dir: Directory to save configuration files
        """
        print(f"Fetching private key...")
        private_key = self.get_private_key()

        print(f"Fetching server recommendations (limit: {total_configs}" + (f", country: {country.upper()}" if country else "") + ")...")
        servers = self.get_server_recommendations(total_configs, country)

        if not servers:
            print("No servers found matching criteria", file=sys.stderr)
            return

        print(f"Found {len(servers)} server(s)")

        # Create output directory if it doesn't exist
        os.makedirs(output_dir, exist_ok=True)

        # Generate and save configs
        for i, server in enumerate(servers, 1):
            try:
                filename, config = self.create_config(server, private_key, dns)
                filepath = os.path.join(output_dir, filename)
                with open(filepath, "w") as f:
                    f.write(config)
                print(f"[{i}/{len(servers)}] Created: {filename}")
            except Exception as e:
                print(f"Error creating config for server: {e}", file=sys.stderr)
                continue

def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Extract NordVPN WireGuard configurations",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List available countries
  %(prog)s --list-countries

  # Set access token as environment variable
  export NORDVPN_ACCESS_TOKEN="your_token_here"

  # Extract 3 configs from any country
  %(prog)s

  # Extract 5 configs from United States
  %(prog)s --country us --count 5

  # Extract configs to specific directory
  %(prog)s --country uk --output ./configs

Common country codes: us, uk, de, fr, nl, ca, au, jp, etc.
"""
    )
    parser.add_argument(
        "--list-countries",
        action="store_true",
        help="List all available country codes and exit"
    )
    parser.add_argument(
        "--token",
        help="NordVPN access token (or set NORDVPN_ACCESS_TOKEN env variable)",
        default=os.environ.get("NORDVPN_ACCESS_TOKEN")
    )
    parser.add_argument(
        "--country", "-c",
        help="Filter by country code (e.g., us, uk, de)",
        type=str
    )
    parser.add_argument(
        "--count", "-n",
        help="Number of configurations to extract (default: 3)",
        type=int,
        default=3
    )
    parser.add_argument(
        "--dns",
        help=f"DNS servers (default: {NordVPNConfigExtractor.DEFAULT_DNS})",
        default=NordVPNConfigExtractor.DEFAULT_DNS
    )
    parser.add_argument(
        "--output", "-o",
        help="Output directory for config files (default: current directory)",
        default="."
    )
    args = parser.parse_args()

    # Handle list-countries command (doesn't require token)
    if args.list_countries:
        extractor = NordVPNConfigExtractor(access_token="dummy")
        extractor.list_countries()
        sys.exit(0)

    # Check for access token
    if not args.token:
        print("Error: Access token required. Provide via --token or NORDVPN_ACCESS_TOKEN environment variable", file=sys.stderr)
        sys.exit(1)

    # Extract configs
    extractor = NordVPNConfigExtractor(args.token)
    extractor.extract_configs(
        total_configs=args.count,
        country=args.country,
        dns=args.dns,
        output_dir=args.output
    )
    print("\nDone!")


if __name__ == "__main__":
    main()
