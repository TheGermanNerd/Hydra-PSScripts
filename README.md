# Hydra Community Scripts

A collection of scripts built by and for the community to help automate, extend and troubleshoot **Hydra** environments for Azure Virtual Desktop and Windows 365.

> [!WARNING]
> **These scripts are community contributions and are NOT officially maintained or supported by Hydra.**
> They are not part of the Hydra product, are not covered by Login VSI Support or any SLA, and may change or be removed at any time without notice.

---

## ⚠️ Disclaimer

- **Community-created.** Everything in this repository was written to share knowledge and save other Hydra users some time. It is not an official Login VSI release.
- **Not officially maintained.** There is no guarantee of updates, bug fixes or compatibility with future Hydra versions.
- **No official support.** Please do **not** open Login VSI support tickets for issues with these scripts. Support cases for these scripts will not be handled by Login VSI Support.
- **Use at your own risk.** All scripts are provided "as is", without warranty of any kind, express or implied. The authors and contributors are not liable for any damage, data loss or downtime resulting from their use.
- **Always review before running.** Read and understand every script before you execute it, and test it in a non-production host pool first.

---

## 📂 What's in this repo

| Folder | Description |
| --- | --- |
| `/session-host` | Scripts that run on session hosts (e.g. software installs, Windows Updates, FSLogix configuration) |
| `/host-pool` | Scripts for host pool and lifecycle automation (e.g. domain join, cleanup on host deletion) |
| `/azure` | Azure-side helpers related to Hydra deployments |

*Each script includes a header describing what it does, its requirements and any parameters.*

---

## 🚀 Getting started

1. Clone the repository:
   ```bash
   git clone https://github.com/<your-username>/<repo-name>.git
   ```
2. Browse to the script you need and read its header and comments.
3. Adjust parameters and variables to match your environment.
4. Import the script into Hydra and test it against a non-production host pool.
5. Only then use it in production, with a rollback plan in place.

---

## 🛠️ Getting help

Help is **best effort** and provided by the community, not by Login VSI.

- **Found a bug or have a question about a script?** Open a [GitHub Issue](../../issues).
- **Problem with Hydra itself?** Contact official Hydra Support through your usual channel.

Please include the script name, your Hydra version and any error output from the Hydra script log when opening an issue.

---

## 📄 License

See the [LICENSE](LICENSE) file for details.

---

*Hydra are trademarks of Login VSI. This repository is a community project and is not an official Login VSI product.*
