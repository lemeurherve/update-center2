#!/bin/bash -ex

# Used later for rsyncing updates
UPDATES_SITE="updates.jenkins.io"
RSYNC_USER="www-data"
UPDATES_R2_BUCKETS="westeurope-updates-jenkins-io"
UPDATES_R2_ENDPOINT="https://8d1838a43923148c5cee18ccc356a594.r2.cloudflarestorage.com"

wget --no-verbose -O jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 || { echo "Failed to download jq" >&2 ; exit 1; }
chmod +x jq || { echo "Failed to make jq executable" >&2 ; exit 1; }

export PATH=.:$PATH

"$( dirname "$0" )/generate.sh" ./www2 ./download

# push plugins to mirrors.jenkins-ci.org
chmod -R a+r download
rsync -avz --size-only download/plugins/ ${RSYNC_USER}@${UPDATES_SITE}:/srv/releases/jenkins/plugins

# Invoke a minimal mirrorsync to mirrorbits which will use the 'recent-releases.json' file as input
ssh ${RSYNC_USER}@${UPDATES_SITE} "cat > /tmp/update-center2-rerecent-releases.json" < www2/experimental/recent-releases.json
ssh ${RSYNC_USER}@${UPDATES_SITE} "/srv/releases/sync-recent-releases.sh /tmp/update-center2-rerecent-releases.json"

# push generated index to the production servers
# 'updates' come from tool installer generator, so leave that alone, but otherwise
# delete old sites
chmod -R a+r www2
rsync -acvz www2/ --exclude=/updates --delete ${RSYNC_USER}@${UPDATES_SITE}:/var/www/${UPDATES_SITE}

## TODO: cleanup commands above when https://github.com/jenkins-infra/helpdesk/issues/2649 is ready for production
# Sync CloudFlare R2 buckets content using the updates-jenkins-io profile, excluding 'updates' folder which comes from tool installer generator
aws s3 sync www2/ s3://${UPDATES_R2_BUCKETS}/ --profile updates-jenkins-io --delete --exclude="updates/*" --endpoint-url ${UPDATES_R2_ENDPOINT}

# Sync Azure File Share content
azcopy sync www2/ "${UPDATES_FILE_SHARE_URL}" --recursive=true --delete-destination=true --exclude-path="updates"

# /TIME sync, used by mirrorbits to know the last update date to take in account
echo $(date +%s) > www2/TIME
aws s3 cp www2/TIME s3://${UPDATES_R2_BUCKETS}/ --profile updates-jenkins-io --endpoint-url ${UPDATES_R2_ENDPOINT}
azcopy cp www2/TIME "${UPDATES_FILE_SHARE_URL}" --overwrite=true
