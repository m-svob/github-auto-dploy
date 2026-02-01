# GitHub Auto-Deploy

**Automatically checks your GitHub repository for new versions and triggers deployment with `dploy deploy <branch>` when updates are detected.**


## Features


- ✅ Monitors a GitHub repository for new commits or releases using Cron scripts
- ✅ Automatically triggers deployment scripts (using DPLOY) when changes are detected
- ✅ Simple configuration and setup
- ✅ Logs every run in a .log file


## Installation


Clone the repository:


```bash
git clone https://github.com/m-svob/github-auto-dploy.git
cd github-auto-dploy
```


## Usage


```bash
wget https://raw.githubusercontent.com/m-svob/github-auto-dploy/main/install.sh -O install.sh
bash install.sh
```
