# Asterisk PBX on raspi5l

Household PBX. Asterisk owns the IrishVoip trunk; the Grandstream HT812 ATA and
both softphones are extensions behind it.

```
                         ┌──────────────────────────┐
   PSTN ── IrishVoip ────┤ Asterisk 22 (raspi5l)    │
        SIP/TLS :5098    │ 192.168.10.252           │
        DID 35315342771  │                          │
                         │  101 pavel  (softphone)  │
   Internet ─── TLS ─────┤  102 kai    (softphone)  │
        :5061 + SRTP     │  103 HT812  FXS port 2   │
                         └──────────────────────────┘
```

Configuration lives in `modules/nixos/asterisk.nix` (`smind.services.asterisk`)
and is instantiated in `private/hosts/raspi5l/cfg-raspi5l.nix`.

## Dial plan

| Dialled              | Result                                            |
| -------------------- | ------------------------------------------------- |
| `101` / `102` / `103`| Rings that extension                              |
| `600`                | Echo test — talk and hear yourself back           |
| `00<cc><number>`     | Trunk, `00` stripped (Irish international prefix) |
| `+<cc><number>`      | Trunk, `+` stripped                               |
| `0<number>`          | Trunk, leading `0` replaced by `353`              |
| anything else        | Trunk, unchanged (already E.164, or a short code) |

An exact extension match always beats a pattern. Extensions are `1xx` rather
than `0xx` precisely so they are not a prefix of any dialable number: Irish
national numbers begin `0` and international calls begin `00`, so `001` would
have forced the analog handset to wait out its ~4 s inter-digit timeout on every
internal call. Nothing dialable is exactly `101`/`102`/`103`, so the ATA sends
immediately. Non-geographic ranges that also start with `1` (`1800`, `1850`,
`11811`) are longer and match the `_X.` catch-all normally — verified.

Inbound calls on the DID ring `101`, `102` and `103` simultaneously.

If you ever expose this to UK callers, note that `101` is the UK police
non-emergency number. It has no meaning in the Irish plan, and it is only ever
interpreted locally by this dialplan, but it is worth knowing.

## Codecs

`opus, g722, alaw, ulaw` for the softphones — Opus first, so softphone-to-
softphone calls are full-band and get Opus's own FEC/PLC on lossy mobile links.

The trunk and the ATA are pinned to `alaw, ulaw`: the PSTN is 8 kHz G.711
regardless, and the FXS port feeds an analog handset, so offering anything wider
would only add a pointless transcode. Asterisk transcodes Opus↔G.711 for calls
between a softphone and the trunk or the handset; `codec_opus_open_source` is
present in the package and a Pi 5 handles that comfortably for a household.

## Transports

| Leg                    | Transport                                     |
| ---------------------- | --------------------------------------------- |
| Softphone from the LAN | UDP 5060                                      |
| Softphone from outside | TLS 5061 + SRTP                               |
| HT812 (LAN)            | UDP 5060, no SRTP                             |
| IrishVoip trunk        | TLS, `_sips._tcp` → `connect.irishvoip.com:5098` |

The trunk's TLS transport (`transport-trunk-tls`, bound to 5062) is deliberately
a **separate object** from the inbound listener on 5061. The listener only
appears once ACME has issued a certificate; a client-role transport needs no
certificate of its own, so trunk connectivity never depends on ACME succeeding.
Port 5062 is not opened in the firewall — it originates connections rather than
serving them.

Asterisk logs `The certificate is untrusted` for the trunk connection: PJSIP
does not verify the peer certificate by default (`verify_server` is off). The
session is still encrypted, which matches what the HT812 was already doing.
Turning verification on would need a CA path and a certificate that actually
matches the SRV target's hostname — check before enabling, or the trunk drops.

## Secrets

Extension and trunk passwords are agenix secrets encrypted to the master key.
They never enter the Nix store: `pjsip.conf` is world-readable in `/etc/asterisk`
and ends with an `#include` of `/run/asterisk/pjsip-runtime.conf`, which the
service's pre-start hook writes (mode 0640 `asterisk:asterisk`) from the
decrypted secret paths. The inbound TLS transport is emitted into that same
file, and only when the certificate is readable — so a not-yet-issued ACME
certificate costs you the TLS listener, not the whole PBX.

| Secret                                     | Contents                     |
| ------------------------------------------ | ---------------------------- |
| `generic/asterisk-ext-101-pavel.age`       | SIP password, extension 101  |
| `generic/asterisk-ext-102-kai.age`         | SIP password, extension 102  |
| `generic/asterisk-ext-103-grandstream.age` | SIP password, extension 103  |
| `generic/asterisk-trunk-irishvoip.age`     | IrishVoip SIP password       |

To replace one:

```bash
printf '%s' 'NEW-PASSWORD' | age -e -r "$(grep -o 'age1[a-z0-9]*' \
  private/hosts/raspi5l/cfg-raspi5l.nix | head -1)" \
  -o private/secrets/generic/asterisk-trunk-irishvoip.age
./setup -k raspi5l          # rekey (needs the TPM-held master key)
```

Asterisk is deliberately **not** restarted by a configuration change (upstream
sets `restartIfChanged = false` so a switch cannot drop a call in progress).
After changing secrets or dial plan: `systemctl restart asterisk`.

## Remaining manual steps

Everything below is outside this repository.

1. **DNS.** Create `pbx.7mind.io` → `45.11.171.73` (A, or CNAME to
   `home.7mind.io`) in Route53. Needed both for the ACME DNS-01 challenge and
   for `external_signaling_address`.

2. **UDM-Pro port forwards**, to 192.168.10.252:

   | Proto | Port        | Purpose            |
   | ----- | ----------- | ------------------ |
   | TCP   | 5061        | SIP over TLS       |
   | UDP   | 12000–12200 | RTP / SRTP media   |

   **Do not forward UDP 5060.** It is open on the host for the LAN only; every
   SIP scanner on the internet probes 5060 and nothing else by default.

3. **Verify the Route53 credentials file format.** `security.acme` passes
   `aws-secrets-7mind` to lego as a systemd `EnvironmentFile`, which requires
   plain `KEY=value` lines. That secret was written for `pkgs.ip-update`, which
   `source`s it as a shell script, so it may contain `export` prefixes or the
   extra `ZONE=` variable. `systemctl status acme-pbx.7mind.io` after the first
   deploy will say if lego could not authenticate; if so, write a dedicated
   secret with just `AWS_ACCESS_KEY_ID=` and `AWS_SECRET_ACCESS_KEY=`.

4. **Retire the ATA's direct IrishVoip registration.** See below.

## Deploying

```bash
./setup -k raspi5l          # rekey the new secrets (TPM)
./setup -s raspi5l -ncs     # build + switch
```

Then:

```bash
ssh raspi5l -- systemctl status asterisk
ssh raspi5l -- asterisk -rx 'pjsip show endpoints'
ssh raspi5l -- asterisk -rx 'pjsip show registrations'   # irishvoip -> Registered
ssh raspi5l -- asterisk -rx 'pjsip show transports'      # udp, trunk-tls, +tls once cert exists
```

## Grandstream HT812

`sip.home.7mind.io` (192.168.10.50), web UI user `admin`.

Already configured:

- **Profile 2** → `192.168.10.252`, UDP, registration on, NAT traversal off,
  vocoders PCMA / PCMU / G722 / Opus, local SIP port 6060, RTP 6004.
- **FXS port 2** → user/auth ID `103`, profile 2, enabled.

**Profile 1 and FXS port 1 were left completely untouched** — port 1 is still
registered directly to IrishVoip with the DID, exactly as before. Changes were
posted as individual parameters rather than as a whole form, because the device
renders password fields blank and echoing the form back would have submitted an
empty `P4120`, potentially clearing the port 1 credential, which cannot be read
back off the device.

Plug the handset into **port 2** and confirm `103` works, then disable port 1
(FXS Ports → *Enable Port 1* → No, i.e. `P4595=0`).

Disabling port 1 is a tidiness measure, not a correctness requirement:
IrishVoip accepts **multiple simultaneous contact bindings** for the DID. That
was verified directly — while a test Asterisk was registered, the registrar's
200 OK listed both bindings:

```
Contact: <sips:35315342771@45.11.171.73:33155;transport=tls;...
           +sip.instance="<urn:uuid:...-000B82DFD3F6>">;expires=164,   <- the HT812
         <sip:35315342771@192.168.10.15:15080;line=sketngs>;expires=300  <- Asterisk
```

So inbound calls fork to every registered contact. Leaving port 1 enabled means
an inbound call rings the port 1 handset *and* Asterisk (which rings 101/102/103)
— harmless but confusing, and the analog handset would ring twice over if it
were on both ports. That `+sip.instance` UUID embedding the ATA's MAC
(`000B82DFD3F6`) is also how you can always tell the two bindings apart.

## Softphone settings

| Field         | Value                                       |
| ------------- | ------------------------------------------- |
| SIP user      | `101` (pavel) / `102` (kai)                 |
| Auth user     | same                                        |
| Domain / host | `pbx.7mind.io` away, `192.168.10.252` at home |
| Transport     | TLS, port 5061 (away) — UDP 5060 on the LAN |
| Media         | SRTP, "optional"/"best effort"              |
| Codecs        | Opus first, then G.722, then G.711 A-law    |

Recommended clients: Linphone or Groundwire (both do Opus + SRTP + TLS and
handle push/background registration on mobile).

Dial `600` first — it answers and echoes your audio back, which is the quickest
way to tell whether the media path and the codec are working end to end.

## Security posture

- Only TLS is exposed; SIP over UDP stays on the LAN.
- 28-character random passwords per extension.
- `fail2ban` jail on the Asterisk journal, 5 failures / 10 min → 24 h ban.
  Verified with `fail2ban-regex` against real Asterisk output: it matches
  `InvalidAccountID` (probing an unknown extension) and `ChallengeResponseFailed`
  (wrong password), and ignores `ChallengeSent` and `SuccessfulAuth`.
- `disable_multi_domain=yes`; no `anonymous` endpoint, so unmatched requests are
  rejected rather than landing in a context.
- `user_agent=PBX` — no version banner for scanners to fingerprint.

Residual risk worth knowing about: any extension can dial out through the trunk,
so a compromised softphone credential means toll fraud. The passwords are strong
and rate-limited, but if you want a hard ceiling, the usual measures are a
per-day call-duration cap or restricting expensive destination prefixes in the
`outbound` context.

## Caveats

- **`external_signaling_address` is resolved once, at start-up.** If the site's
  public IP changes, restart Asterisk. The address has been stable
  (`45.11.171.73`) and `pkgs.ip-update` exists for dyndns, but nothing currently
  ties the two together.
- **Emergency calls.** `112`/`999` are passed to IrishVoip unmodified. Whether
  they connect, and what address they present, is entirely up to the provider —
  do not rely on this PBX for emergency calling.
- **SRV.** The trunk deliberately has no `outbound_proxy`: PJSIP resolves
  `irishvoip.com` per RFC 3263 and follows the SRV records by itself — verified
  by observation, the REGISTER went to `99.81.91.49:5098`, the `_sips._tcp`
  target, not to the `irishvoip.com` A record. (`res_resolver_unbound` is absent
  from the nixpkgs build, but pjproject's own resolver handles SRV, so that does
  not matter here.)
