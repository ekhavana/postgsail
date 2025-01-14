# PostgSail Unit test 

if [[ -z "${PGSAIL_DB_URI}" ]]; then
  echo "PGSAIL_DB_URI is undefined"
  exit 1
fi
if [[ -z "${PGSAIL_API_URI}" ]]; then
  echo "PGSAIL_API_URI is undefined"
  exit 1
fi

#npm install
npm install -g pnpm && pnpm install
# settings
export mymocha="./node_modules/mocha/bin/_mocha"
mkdir -p output/ && rm -rf output/*

$mymocha index.js --reporter ./node_modules/mochawesome --reporter-options reportDir=output/,reportFilename=report1.html
if [ $? -eq 0 ]; then
    echo OK
else
    echo mocha index.js
    exit 1
fi

$mymocha index2.js --reporter ./node_modules/mochawesome --reporter-options reportDir=output/,reportFilename=report2.html
if [ $? -eq 0 ]; then
    echo OK
else
    echo mocha index2.js
    exit 1
fi

# https://www.postgresql.org/docs/current/app-psql.html
# run cron jobs
#psql -U ${POSTGRES_USER} -h 172.30.0.1 signalk < sql/cron_run_jobs.sql > output/cron_run_jobs.sql.output
psql ${PGSAIL_DB_URI} < sql/cron_run_jobs.sql > output/cron_run_jobs.sql.output
diff sql/cron_run_jobs.sql.output output/cron_run_jobs.sql.output > /dev/null
#diff -u sql/cron_run_jobs.sql.output output/cron_run_jobs.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL cron_run_jobs.sql FAILED
    diff -u sql/cron_run_jobs.sql.output output/cron_run_jobs.sql.output
    exit 1
fi

# handle post processing
#psql -U ${POSTGRES_USER} -h 172.30.0.1 signalk < sql/cron_post_jobs.sql > output/cron_post_jobs.sql.output
psql ${PGSAIL_DB_URI} < sql/cron_post_jobs.sql > output/cron_post_jobs.sql.output
diff sql/cron_post_jobs.sql.output output/cron_post_jobs.sql.output > /dev/null
#diff -u sql/cron_post_jobs.sql.output output/cron_post_jobs.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL cron_post_jobs.sql FAILED
    diff -u sql/cron_post_jobs.sql.output output/cron_post_jobs.sql.output
    exit 1
fi

$mymocha index3.js --reporter ./node_modules/mochawesome --reporter-options reportDir=output/,reportFilename=report3.html
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo mocha index3.js
    exit 1
fi

# Grafana Auth Proxy and role unit tests
psql ${PGSAIL_DB_URI} < sql/grafana.sql > output/grafana.sql.output
diff sql/grafana.sql.output output/grafana.sql.output > /dev/null
#diff -u sql/grafana.sql.output output/grafana.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL grafana.sql FAILED
    diff -u sql/grafana.sql.output output/grafana.sql.output
    exit 1
fi

# Telegram and role unit tests
psql ${PGSAIL_DB_URI} < sql/telegram.sql > output/telegram.sql.output
diff sql/telegram.sql.output output/telegram.sql.output > /dev/null
#diff -u sql/telegram.sql.output output/telegram.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL telegram.sql FAILED
    diff -u sql/telegram.sql.output output/telegram.sql.output
    exit 1
fi

# Badges unit tests
psql ${PGSAIL_DB_URI} < sql/badges.sql > output/badges.sql.output
diff sql/badges.sql.output output/badges.sql.output > /dev/null
#diff -u sql/badges.sql.output output/badges.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL badges.sql FAILED
    diff -u sql/badges.sql.output output/badges.sql.output
    exit
fi

# Summary unit tests
psql ${PGSAIL_DB_URI} < sql/summary.sql > output/summary.sql.output
diff sql/summary.sql.output output/summary.sql.output > /dev/null
#diff -u sql/summary.sql.output output/summary.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL summary.sql FAILED
    diff -u sql/summary.sql.output output/summary.sql.output
    exit 1
fi

$mymocha index4.js --reporter ./node_modules/mochawesome --reporter-options reportDir=output/,reportFilename=report4.html
if [ $? -eq 0 ]; then
    echo OK
else
    echo mocha index4.js
    exit 1
fi

# Monitoring unit tests
psql ${PGSAIL_DB_URI} < sql/monitoring.sql > output/monitoring.sql.output
diff sql/monitoring.sql.output output/monitoring.sql.output > /dev/null
#diff -u sql/monitoring.sql.output output/monitoring.sql.output | wc -l
#echo 0
if [ $? -eq 0 ]; then
    echo OK
else
    echo SQL monitoring.sql FAILED
    diff -u sql/monitoring.sql.output output/monitoring.sql.output
    exit 1
fi