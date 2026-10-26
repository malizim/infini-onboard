# Infini-Onboard seed

This is the source for the first-stage Debian host onboarding seed. The
canonical repository is `infini/infini-onboard` in Infini Code; its public
GitHub mirror at `https://github.com/malizim/infini-onboard` provides the
out-of-band first contact before a host can join Tailscale. This repository
contains only the onboarding script and this operator-facing description.
Host inventory, site profiles, credentials, and IaC state stay in private
Infini-Ops/site repositories.

## Current scope

`onboard.sh` joins a Debian host to an already-running site's Forgejo. It
installs the minimum Git/SSH/Tailscale prerequisites, enrolls Tailscale,
registers the host's SSH public key, clones or fast-forwards Infini-Ops, then
applies the site's time helper and optionally clones named repositories. It
does not create a new site, deploy Forgejo, install a CI runner, or provision
applications. Domain join remains an explicit later option.

The operator supplies the target site's Forgejo HTTPS URL and SSH endpoint.
The seed is retrieved over verified HTTPS before tailnet enrollment; private
site configuration is fetched only after Tailscale and key enrollment.

## Release and verification requirements

The canonical Infini Code repository and public GitHub mirror have been
created. The initial seed publication and mirror verification are in progress.
Before publishing a release:

1. Review the script and keep the seed free of site-specific hostnames,
   addresses, credentials, and private inventory.
2. Validate in a disposable Debian VM with no pre-existing SSH key or Forgejo
   checkout, using the site's interactive Tailscale and Forgejo key-enrollment
   path.
3. Record the exact source commit, supported Debian release, resulting host
   profile, and evidence that time, SSH, and repository access were verified.
4. Publish a pinned release with a checksum or signature. Operators download,
   inspect, verify, then run it; never recommend `curl | sh`.
5. Mirror from Infini-Code to the public GitHub repo. GitHub is the
   first-contact seed and recovery copy, not the write origin.

Do not mirror the full Infini-Ops repository to make the seed available.
