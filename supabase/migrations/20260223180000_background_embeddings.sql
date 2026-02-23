-- Background embeddings via pg_cron
--
-- Schedules embed_pending() (defined in vector_search migration) to run
-- every 10 minutes, processing any meetings or utterances that are still
-- missing embeddings.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Guard: unschedule first so this migration is idempotent on re-run.
SELECT cron.unschedule('embed-pending')
FROM   cron.job
WHERE  jobname = 'embed-pending';

SELECT cron.schedule('embed-pending', '*/10 * * * *', 'SELECT embed_pending()');
