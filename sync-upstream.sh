#!/bin/bash
# =============================================================================
# UniTime Upstream Sync Script
# DigiPen R&D — Automated fork maintenance
#
# Usage:
#   ./sync-upstream.sh              # Check + merge + build
#   ./sync-upstream.sh --deploy     # Check + merge + build + deploy to Docker
#   ./sync-upstream.sh --dry-run    # Only check, don't change anything
# =============================================================================

set -e

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"
ARCHIVE_DIR="$SCRIPT_DIR/archives"
LOG_DIR="$SCRIPT_DIR/logs"
DOCKER_DIR="$SCRIPT_DIR/../docker-deploy"
LOG_FILE="$LOG_DIR/sync-$(date +%Y-%m-%d_%H-%M-%S).log"

# ── Parse flags ──────────────────────────────────────────────────────────────
DEPLOY=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --deploy)  DEPLOY=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: ./sync-upstream.sh [--deploy] [--dry-run]"
            echo ""
            echo "  --deploy    After successful build, deploy WAR to Docker and restart"
            echo "  --dry-run   Only check for updates, don't merge or build"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown flag: $arg${NC}"
            echo "Run ./sync-upstream.sh --help for usage"
            exit 1
            ;;
    esac
done

# ── Setup logging ────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo -e "$2$1${NC}"
}

# ── dump_database ────────────────────────────────────────────────────────────
# Dumps the UniTime MySQL DB from the unitime-db container, gzipped, into the
# current archive dir. Sets DB_DUMP_STATUS for version-info.txt.
#
# Runs as the `timetable` user (root password is randomized by the compose
# file via MYSQL_RANDOM_ROOT_PASSWORD=yes). --no-tablespaces avoids the
# PROCESS-privilege error on MySQL 8+ when dumping as a non-root user.
#
# Note: --dry-run exits before Stage 4, so this is never reached in dry mode.
dump_database() {
    local dump_file="$ARCHIVE_SUBDIR/db-dump.sql.gz"

    if ! docker ps --format '{{.Names}}' | grep -q '^unitime-db$'; then
        log "MySQL container 'unitime-db' is not running — skipping DB dump" "$YELLOW"
        log "Archive will contain WAR only; restore is code-only, not data." "$YELLOW"
        DB_DUMP_STATUS="SKIPPED (unitime-db container not running)"
        return 0
    fi

    log "Dumping MySQL 'timetable' DB via docker exec (gzipped)..." "$NC"

    # MYSQL_PWD keeps the password out of the container's process list.
    # PIPESTATUS check catches mysqldump failure even though gzip succeeds.
    docker exec -e MYSQL_PWD=unitime unitime-db \
        mysqldump --no-tablespaces --single-transaction --routines --triggers \
        -u timetable timetable 2>> "$LOG_FILE" | gzip > "$dump_file"
    local dump_status=${PIPESTATUS[0]}
    local gzip_status=${PIPESTATUS[1]}

    if [ "$dump_status" -ne 0 ] || [ "$gzip_status" -ne 0 ] || [ ! -s "$dump_file" ]; then
        log "ERROR: mysqldump failed (mysqldump=$dump_status gzip=$gzip_status). See $LOG_FILE" "$RED"
        rm -f "$dump_file"
        DB_DUMP_STATUS="FAILED"
        return 1
    fi

    local dump_size
    dump_size=$(du -h "$dump_file" | cut -f1)
    log "Database dump saved: $dump_file ($dump_size)" "$GREEN"
    DB_DUMP_STATUS="$dump_file ($dump_size)"
    return 0
}

# ── health_check ─────────────────────────────────────────────────────────────
# Verifies UniTime responds on localhost:8888 after a deploy. Returns 0 on
# success, 1 on failure.
#
# docker-compose up -d exits 0 as soon as the container starts, but UniTime
# may crash during Tomcat startup or fail to deploy the WAR — this check
# catches that. curl -f fails on HTTP 4xx/5xx; 2xx/3xx pass (UniTime root
# often 302s to a login page, which is healthy).
#
# Tuning: 10×3s = 30s total. Cold UniTime startup is typically 20–40s on
# this hardware, so a fresh build may need more. Bump HEALTH_RETRIES if you
# see false-positive rollbacks on first boot.
health_check() {
    local url="http://localhost:8888/"
    local retries=10
    local delay=3
    local i

    log "Health check: polling $url (up to $((retries * delay))s)..." "$NC"

    for ((i = 1; i <= retries; i++)); do
        if curl -fsS --max-time 5 -o /dev/null "$url" 2>> "$LOG_FILE"; then
            log "Health check passed on attempt $i" "$GREEN"
            return 0
        fi
        log "  attempt $i/$retries — not ready, sleeping ${delay}s" "$CYAN"
        sleep "$delay"
    done

    log "Health check FAILED after $retries attempts" "$RED"
    return 1
}

# ── rollback ─────────────────────────────────────────────────────────────────
# Restores the most recent archived WAR into the Docker volume and restarts
# the stack. Called when health_check fails after a deploy.
#
# Scope:
#   - Restores code (WAR) only.
#   - Does NOT restore the DB dump — Hibernate may have mutated the schema
#     on the new container's startup; blindly restoring the old DB would
#     wipe any transactions written since then. Restore manually from
#     $ARCHIVE_SUBDIR/db-dump.sql.gz if needed.
#   - Does NOT touch git history — the merge commit stays so the failing
#     build is reproducible. `git reset --hard HEAD~1` is available
#     manually after investigation.
#
# Exit codes: exits 2 if rollback itself fails (missing archive, compose
# error, or post-rollback health still failing). Returns 0 on success; the
# caller then exits 1 to signal "upgrade failed but rollback succeeded".
rollback() {
    log "" ""
    log "=== ROLLBACK: restoring last archived WAR ===" "$YELLOW"

    local latest_archive
    latest_archive=$(ls -1dt "$ARCHIVE_DIR"/v*/ 2>/dev/null | head -1)
    latest_archive="${latest_archive%/}"

    if [ -z "$latest_archive" ] || [ ! -f "$latest_archive/UniTime.war" ]; then
        log "ROLLBACK FAILED: no archived WAR found under $ARCHIVE_DIR" "$RED"
        log "Docker containers are in a broken state — manual intervention required." "$RED"
        exit 2
    fi

    log "Restoring WAR from: $latest_archive" "$NC"

    if ! cp "$latest_archive/UniTime.war" "$DOCKER_DIR/web/UniTime.war"; then
        log "ROLLBACK FAILED: cp to $DOCKER_DIR/web/ errored" "$RED"
        exit 2
    fi

    cd "$DOCKER_DIR/docker"
    if ! docker-compose down >> "$LOG_FILE" 2>&1; then
        log "ROLLBACK FAILED: docker-compose down errored" "$RED"
        cd "$SCRIPT_DIR"
        exit 2
    fi
    if ! docker-compose up -d >> "$LOG_FILE" 2>&1; then
        log "ROLLBACK FAILED: docker-compose up -d errored" "$RED"
        cd "$SCRIPT_DIR"
        exit 2
    fi
    cd "$SCRIPT_DIR"

    log "Rollback WAR deployed. Re-checking health..." "$NC"
    if ! health_check; then
        log "ROLLBACK FAILED: restored WAR also fails health check" "$RED"
        log "Docker state is unknown. Manual intervention required." "$RED"
        exit 2
    fi

    log "Rollback successful — previous version is live." "$GREEN"
    log "NOTE: merge commit is still in git history. After investigating," "$YELLOW"
    log "      drop it with: git reset --hard HEAD~1" "$YELLOW"
    log "NOTE: DB was not restored. If the failed deploy mutated the schema," "$YELLOW"
    log "      restore manually from: $ARCHIVE_SUBDIR/db-dump.sql.gz" "$YELLOW"
    return 0
}

log "========== UniTime Upstream Sync ==========" "$BOLD"
log "Mode: $(if $DRY_RUN; then echo 'DRY RUN'; elif $DEPLOY; then echo 'SYNC + DEPLOY'; else echo 'SYNC + BUILD'; fi)" "$CYAN"

# ── Step 1: Get current version info ─────────────────────────────────────────
log "" ""
log "--- Step 1: Checking current version ---" "$BOLD"

# Pre-flight: refuse to run with a dirty tree. A merge-conflict resolution
# over uncommitted edits can silently drop them; we want the user to commit
# or stash first so their work is recoverable.
if ! git diff --quiet || ! git diff --cached --quiet; then
    log "ERROR: uncommitted changes. Commit or stash first." "$RED"
    exit 1
fi

OUR_BRANCH=$(git branch --show-current)
OUR_COMMIT=$(git rev-parse HEAD)
OUR_COMMIT_SHORT=$(git rev-parse --short HEAD)
OUR_VERSION=$(grep -m1 '<version>' pom.xml | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
OUR_BUILD=$(grep 'build.number=' build.number 2>/dev/null | cut -d= -f2 || echo "?")

log "Branch:  $OUR_BRANCH" "$NC"
log "Version: $OUR_VERSION (build $OUR_BUILD)" "$NC"
log "Commit:  $OUR_COMMIT_SHORT" "$NC"

# ── Step 2: Check upstream ───────────────────────────────────────────────────
log "" ""
log "--- Step 2: Checking upstream ($UPSTREAM_REMOTE/$UPSTREAM_BRANCH) ---" "$BOLD"

# Fetch upstream refs without downloading objects yet
UPSTREAM_COMMIT=$(git ls-remote "$UPSTREAM_REMOTE" "refs/heads/$UPSTREAM_BRANCH" | cut -f1)

if [ -z "$UPSTREAM_COMMIT" ]; then
    log "ERROR: Could not reach upstream remote '$UPSTREAM_REMOTE'" "$RED"
    log "Check your internet connection and that the remote is configured:" "$RED"
    log "  git remote -v" "$NC"
    exit 1
fi

UPSTREAM_COMMIT_SHORT="${UPSTREAM_COMMIT:0:7}"

# Get latest upstream tag (compatible with Windows Git Bash — no -P flag)
UPSTREAM_TAG=$(git ls-remote --tags "$UPSTREAM_REMOTE" | grep -o 'refs/tags/v[0-9][0-9.]*$' | sed 's|refs/tags/||' | sort -V | tail -1)
UPSTREAM_TAG="${UPSTREAM_TAG:-unknown}"

log "Upstream commit: $UPSTREAM_COMMIT_SHORT" "$NC"
log "Latest tag:      $UPSTREAM_TAG" "$NC"

# ── Step 3: Compare ─────────────────────────────────────────────────────────
log "" ""
log "--- Step 3: Comparing versions ---" "$BOLD"

if [ "$OUR_COMMIT" = "$UPSTREAM_COMMIT" ]; then
    log "Already up to date! No changes needed." "$GREEN"
    log "Our commit and upstream/$UPSTREAM_BRANCH are identical." "$GREEN"
    exit 0
fi

# Check if upstream is an ancestor (we're ahead) or if there are new changes
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --quiet

BEHIND=$(git rev-list --count "HEAD..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")
AHEAD=$(git rev-list --count "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH..HEAD")

log "We are $BEHIND commit(s) BEHIND upstream" "$YELLOW"
log "We are $AHEAD commit(s) AHEAD of upstream (our customizations)" "$NC"

if [ "$BEHIND" -eq 0 ]; then
    log "We have all upstream changes (we're ahead with local commits). No update needed." "$GREEN"
    exit 0
fi

log "UPDATE AVAILABLE: $BEHIND new commit(s) from upstream" "$YELLOW"

# ── Show what changed ────────────────────────────────────────────────────────
log "" ""
log "--- Changes summary ---" "$BOLD"

CHANGED_FILES=$(git diff --stat "HEAD...$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" | tail -1)
log "$CHANGED_FILES" "$NC"

log "" ""
log "Files changed:" "$NC"
git diff --name-only "HEAD...$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" | head -30 | while read -r file; do
    log "  $file" "$NC"
done

TOTAL_CHANGED=$(git diff --name-only "HEAD...$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" | wc -l | tr -d ' ')
if [ "$TOTAL_CHANGED" -gt 30 ]; then
    log "  ... and $((TOTAL_CHANGED - 30)) more files" "$CYAN"
fi

# ── Dry run stops here ──────────────────────────────────────────────────────
if $DRY_RUN; then
    log "" ""
    log "=== DRY RUN COMPLETE ===" "$CYAN"
    log "Run without --dry-run to apply the update." "$NC"
    exit 0
fi

# ── Step 4: Archive old version ──────────────────────────────────────────────
log "" ""
log "--- Step 4: Archiving current version ---" "$BOLD"

ARCHIVE_SUBDIR="$ARCHIVE_DIR/v${OUR_VERSION}.${OUR_BUILD}_$(date +%Y-%m-%d)"
mkdir -p "$ARCHIVE_SUBDIR"

# Save old WAR
if [ -f "target/UniTime.war" ]; then
    cp target/UniTime.war "$ARCHIVE_SUBDIR/UniTime.war"
    log "Saved WAR to $ARCHIVE_SUBDIR/UniTime.war" "$NC"
else
    log "No existing WAR file to archive" "$YELLOW"
fi

# Dump MySQL BEFORE merge — an upstream schema migration can corrupt data
# and a WAR-only restore won't recover it.
dump_database

# Save version metadata
cat > "$ARCHIVE_SUBDIR/version-info.txt" <<EOF
Version:        $OUR_VERSION (build $OUR_BUILD)
Branch:         $OUR_BRANCH
Commit:         $OUR_COMMIT
Archived:       $(date)
Reason:         Upstream update to $UPSTREAM_TAG ($UPSTREAM_COMMIT_SHORT)
Changes behind: $BEHIND commit(s)
DB dump:        ${DB_DUMP_STATUS:-not attempted}
EOF

log "Version info saved to $ARCHIVE_SUBDIR/version-info.txt" "$NC"
log "Old version archived successfully" "$GREEN"

# ── Step 5: Merge upstream ──────────────────────────────────────────────────
log "" ""
log "--- Step 5: Merging upstream changes ---" "$BOLD"

# Attempt merge
MERGE_MSG="Merge upstream UniTime $UPSTREAM_TAG ($UPSTREAM_COMMIT_SHORT)"

if ! git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-commit --no-ff 2>> "$LOG_FILE"; then
    # Check for conflicts
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U)

    if [ -n "$CONFLICT_FILES" ]; then
        log "" ""
        log "MERGE CONFLICTS DETECTED!" "$RED"
        log "The following files have conflicts:" "$RED"
        echo "$CONFLICT_FILES" | while read -r file; do
            log "  CONFLICT: $file" "$RED"
        done

        log "" ""
        log "To resolve manually:" "$YELLOW"
        log "  1. Open each conflicted file and resolve the <<<< ==== >>>> markers" "$NC"
        log "  2. git add <resolved-file>" "$NC"
        log "  3. git commit -m \"$MERGE_MSG\"" "$NC"
        log "  4. Re-run: ./sync-upstream.sh $(if $DEPLOY; then echo '--deploy'; fi)" "$NC"
        log "" ""
        log "To abort the merge:" "$YELLOW"
        log "  git merge --abort" "$NC"

        # Abort the merge so we leave the repo clean
        git merge --abort
        log "" ""
        log "Merge aborted — repo is back to its original state." "$YELLOW"
        log "Old version preserved in: $ARCHIVE_SUBDIR" "$NC"
        exit 1
    fi
fi

# Commit the merge
git commit -m "$MERGE_MSG" >> "$LOG_FILE" 2>&1
NEW_COMMIT_SHORT=$(git rev-parse --short HEAD)
log "Merge successful! New commit: $NEW_COMMIT_SHORT" "$GREEN"

# ── Step 6: Build ────────────────────────────────────────────────────────────
log "" ""
log "--- Step 6: Building UniTime ---" "$BOLD"
log "Running: mvn package -DskipTests (this may take a few minutes...)" "$NC"

if mvn package -DskipTests >> "$LOG_FILE" 2>&1; then
    log "Build SUCCESSFUL!" "$GREEN"

    NEW_VERSION=$(grep -m1 '<version>' pom.xml | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
    NEW_BUILD=$(grep 'build.number=' build.number 2>/dev/null | cut -d= -f2 || echo "?")
    log "New version: $NEW_VERSION (build $NEW_BUILD)" "$GREEN"
    log "WAR file: target/UniTime.war" "$NC"
else
    log "BUILD FAILED!" "$RED"
    log "Check the full log: $LOG_FILE" "$RED"
    log "Old version preserved in: $ARCHIVE_SUBDIR" "$YELLOW"
    log "You may want to revert the merge: git reset --hard HEAD~1" "$YELLOW"
    exit 1
fi

# ── Step 7: Deploy (optional) ───────────────────────────────────────────────
if $DEPLOY; then
    log "" ""
    log "--- Step 7: Deploying to Docker ---" "$BOLD"

    if [ ! -d "$DOCKER_DIR" ]; then
        log "ERROR: Docker directory not found at: $DOCKER_DIR" "$RED"
        log "WAR file is ready at target/UniTime.war — deploy manually." "$YELLOW"
        exit 1
    fi

    cp target/UniTime.war "$DOCKER_DIR/web/UniTime.war"
    log "WAR copied to Docker volume" "$NC"

    cd "$DOCKER_DIR/docker"
    docker-compose down >> "$LOG_FILE" 2>&1
    docker-compose build unitime-web >> "$LOG_FILE" 2>&1
    docker-compose up -d >> "$LOG_FILE" 2>&1
    cd "$SCRIPT_DIR"

    log "Docker containers restarted. Verifying health..." "$NC"

    if ! health_check; then
        log "New deploy failed health check — triggering rollback." "$RED"
        rollback
        # rollback exits 2 on its own failure; reaching here = rollback OK.
        log "Upgrade rolled back. Previous version is live." "$YELLOW"
        exit 1
    fi

    log "Deploy successful and verified!" "$GREEN"
    log "Verify at: http://localhost:8888 -> Help -> About" "$CYAN"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "" ""
log "========== Sync Complete ==========" "$GREEN"
log "Previous: v${OUR_VERSION}.${OUR_BUILD} ($OUR_COMMIT_SHORT)" "$NC"
log "Current:  v${NEW_VERSION:-$OUR_VERSION}.${NEW_BUILD:-$OUR_BUILD} ($NEW_COMMIT_SHORT)" "$NC"
log "Archive:  $ARCHIVE_SUBDIR" "$NC"
log "Log:      $LOG_FILE" "$NC"
