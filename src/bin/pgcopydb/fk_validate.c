/*
 * src/bin/pgcopydb/fk_validate.c
 *	 Implementation of a CLI to copy a database between two Postgres instances
 *
 * Validation of the foreign keys that --defer-validate-fks created NOT VALID.
 * It runs once the clone is done and the source snapshot is released, while
 * the changes are applied when following. A failed validation is recorded and
 * logged, it never stops the other validations, nor the follow process.
 */

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "postgres_fe.h"
#include "pqexpbuffer.h"

#include "catalog.h"
#include "cli_root.h"
#include "copydb.h"
#include "fk_validate.h"
#include "log.h"
#include "pgsql.h"
#include "schema.h"
#include "signals.h"
#include "string_utils.h"
#include "summary.h"

static bool fk_validate_start_workers(CopyDataSpec *specs,
									  pid_t *pids,
									  int jobs,
									  int *started);
static bool fk_validate_wait_workers(pid_t *pids, int count);
static bool fk_validate_send_tables(CopyDataSpec *specs,
									uint32_t *reloids,
									int count);
static bool fk_validate_send_stop(CopyDataSpec *specs, int jobs);
static bool fk_validate_table(CopyDataSpec *specs, uint32_t reloid);
static bool fk_validate_constraint_by_oid(CopyDataSpec *specs, uint32_t oid);


/*
 * fk_validate_start_supervisor starts the foreign key validation supervisor
 * process, and does not wait for it.
 */
bool
fk_validate_start_supervisor(CopyDataSpec *specs, pid_t *pidOut)
{
	/*
	 * Flush stdio channels just before fork, to avoid double-output problems.
	 */
	fflush(stdout);
	fflush(stderr);

	int fpid = fork();

	switch (fpid)
	{
		case -1:
		{
			log_error("Failed to fork foreign key validation supervisor "
					  "process: %m");
			return false;
		}

		case 0:
		{
			/* child process runs the command */
			(void) set_ps_title("pgcopydb: validate foreign keys supervisor");

			if (!fk_validate_supervisor(specs))
			{
				log_error("Failed to validate foreign keys on target, "
						  "see above for details");
				exit(EXIT_CODE_INTERNAL_ERROR);
			}

			exit(EXIT_CODE_QUIT);
		}

		default:
		{
			/* fork succeeded, in parent */
			if (pidOut != NULL)
			{
				*pidOut = fpid;
			}
			break;
		}
	}

	return true;
}


/*
 * fk_validate_supervisor queues the tables that have deferred foreign keys
 * left to validate, the largest tables first, to as many workers as
 * --index-jobs, and waits for them. The foreign keys of a table are validated
 * one after the other by the same worker: VALIDATE CONSTRAINT takes a SHARE
 * UPDATE EXCLUSIVE lock on the table, which conflicts with itself.
 *
 * On SIGTERM, SIGINT or SIGQUIT the signal is forwarded to the workers, which
 * cancel their running validation. What is left is retried on resume.
 *
 * It returns false only on internal errors: a foreign key that fails to
 * validate is recorded in our catalogs and logged by its worker.
 */
bool
fk_validate_supervisor(CopyDataSpec *specs)
{
	pid_t pid = getpid();

	log_notice("Started foreign key validation supervisor %d [%d]",
			   pid, getppid());

	DatabaseCatalog *sourceDB = &(specs->catalogs.source);

	if (!catalog_open(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	uint32_t *reloids = NULL;
	int count = 0;

	if (!catalog_list_fk_validation_pending_tables(sourceDB, &reloids, &count))
	{
		/* errors have already been logged */
		(void) catalog_close(sourceDB);
		return false;
	}

	if (count == 0)
	{
		log_info("No deferred foreign keys left to validate");
		return catalog_close(sourceDB);
	}

	int jobs = count < specs->indexJobs ? count : specs->indexJobs;

	log_info("Validating the deferred foreign keys of %d tables "
			 "using %d processes",
			 count, jobs);

	if (!summary_start_timing(sourceDB, TIMING_SECTION_VALIDATE_FKS))
	{
		/* errors have already been logged */
		free(reloids);
		(void) catalog_close(sourceDB);
		return false;
	}

	/* each worker opens its own SQLite connection, see vacuum_supervisor */
	if (!catalog_close(sourceDB))
	{
		/* errors have already been logged */
		free(reloids);
		return false;
	}

	pid_t *pids = (pid_t *) calloc(jobs, sizeof(pid_t));

	if (pids == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		free(reloids);
		return false;
	}

	int started = 0;

	if (!fk_validate_start_workers(specs, pids, jobs, &started))
	{
		log_error("Failed to start foreign key validation workers, "
				  "see above for details");
		free(reloids);

		/* the workers that have been started still need to stop */
		(void) fk_validate_send_stop(specs, started);
		(void) fk_validate_wait_workers(pids, started);
		free(pids);

		return false;
	}

	/* stop the workers even when we failed to queue every table */
	bool queued = fk_validate_send_tables(specs, reloids, count);
	bool stopped = fk_validate_send_stop(specs, jobs);

	free(reloids);

	/* never fail fast: a worker error must not stop the follow process */
	bool workersOk = fk_validate_wait_workers(pids, jobs);

	free(pids);

	if (!workersOk)
	{
		log_error("Some foreign key validation worker process(es) have "
				  "exited with error, see above for details");
	}

	if (!catalog_open(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	int pending = 0;
	int failed = 0;

	bool done =
		summary_stop_timing(sourceDB, TIMING_SECTION_VALIDATE_FKS) &&
		catalog_count_fk_validation(sourceDB, &pending, &failed);

	if (done)
	{
		TopLevelTiming *timing =
			&(topLevelTimingArray[TIMING_SECTION_VALIDATE_FKS]);

		if (pending == 0)
		{
			log_info("Validated all the deferred foreign keys in %s",
					 timing->ppDuration);
		}
		else
		{
			log_warn("Deferred foreign keys left to validate after %s: "
					 "%d, of which %d failed to validate, "
					 "see above for details",
					 timing->ppDuration, pending, failed);
		}
	}

	if (!catalog_close(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	return queued && stopped && workersOk && done;
}


/*
 * fk_validate_start_workers starts the given number of worker processes, and
 * registers their pids. It sets started to the count of workers started.
 */
static bool
fk_validate_start_workers(CopyDataSpec *specs, pid_t *pids, int jobs,
						  int *started)
{
	*started = 0;

	for (int i = 0; i < jobs; i++)
	{
		/*
		 * Flush stdio channels just before fork, to avoid double-output
		 * problems.
		 */
		fflush(stdout);
		fflush(stderr);

		int fpid = fork();

		switch (fpid)
		{
			case -1:
			{
				log_error("Failed to fork a foreign key validation worker "
						  "process: %m");
				return false;
			}

			case 0:
			{
				/* child process runs the command */
				(void) set_ps_title("pgcopydb: validate foreign keys worker");

				if (!fk_validate_worker(specs))
				{
					/* errors have already been logged */
					exit(EXIT_CODE_INTERNAL_ERROR);
				}

				exit(EXIT_CODE_QUIT);
			}

			default:
			{
				/* fork succeeded, in parent */
				pids[(*started)++] = fpid;
				break;
			}
		}
	}

	return true;
}


/*
 * fk_validate_wait_workers waits until the given worker processes have
 * exited, and forwards them the termination signal that we receive. It
 * returns true when all the workers exited successfully.
 */
static bool
fk_validate_wait_workers(pid_t *pids, int count)
{
	bool allReturnCodeAreZero = true;
	bool forwarded = false;
	int running = count;

	while (running > 0)
	{
		if (!forwarded && (asked_to_stop || asked_to_stop_fast || asked_to_quit))
		{
			int sig = get_current_signal(SIGTERM);

			log_notice("Forwarding %s to foreign key validation workers",
					   signal_to_string(sig));

			for (int i = 0; i < count; i++)
			{
				if (pids[i] > 0 && kill(pids[i], sig) != 0 && errno != ESRCH)
				{
					log_warn("Failed to signal foreign key validation "
							 "worker %d: %m",
							 pids[i]);
				}
			}

			forwarded = true;
		}

		for (int i = 0; i < count; i++)
		{
			if (pids[i] <= 0)
			{
				continue;
			}

			int status = 0;
			pid_t pid = waitpid(pids[i], &status, WNOHANG);

			if (pid == 0 || (pid == -1 && errno == EINTR))
			{
				continue;
			}

			pids[i] = 0;
			--running;

			if (pid == -1)
			{
				log_error("Failed to wait for foreign key validation "
						  "worker: %m");
				allReturnCodeAreZero = false;
				continue;
			}

			int returnCode = WIFEXITED(status) ? WEXITSTATUS(status) : 0;
			int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;

			if (returnCode != 0 || !signal_is_handled(sig))
			{
				allReturnCodeAreZero = false;

				log_error("Foreign key validation worker %d exited "
						  "with code %d%s%s",
						  pid,
						  returnCode,
						  sig != 0 ? " and signal " : "",
						  sig != 0 ? signal_to_string(sig) : "");
			}
		}

		if (running > 0)
		{
			pg_usleep(100 * 1000); /* 100 ms */
		}
	}

	return allReturnCodeAreZero;
}


/*
 * fk_validate_send_tables queues the given table OIDs for the workers.
 */
static bool
fk_validate_send_tables(CopyDataSpec *specs, uint32_t *reloids, int count)
{
	for (int i = 0; i < count; i++)
	{
		QMessage mesg = { .type = QMSG_TYPE_FK_RELOID, .data.oid = reloids[i] };

		log_debug("fk_validate_send_tables: %u", reloids[i]);

		if (!queue_send(&(specs->fkValidateQueue), &mesg))
		{
			/* errors have already been logged */
			return false;
		}
	}

	return true;
}


/*
 * fk_validate_send_stop sends one STOP message per worker.
 */
static bool
fk_validate_send_stop(CopyDataSpec *specs, int jobs)
{
	bool success = true;

	for (int i = 0; i < jobs; i++)
	{
		QMessage stop = { .type = QMSG_TYPE_STOP, .data.oid = 0 };

		log_debug("Send STOP message to foreign key validation queue %d",
				  specs->fkValidateQueue.qId);

		if (!queue_send(&(specs->fkValidateQueue), &stop))
		{
			/* errors have already been logged */
			success = false;
		}
	}

	return success;
}


/*
 * fk_validate_worker validates the foreign keys of the tables received from
 * the queue, until it receives a STOP message. It returns false only on
 * internal errors, a foreign key that fails to validate is recorded and the
 * worker carries on.
 */
bool
fk_validate_worker(CopyDataSpec *specs)
{
	pid_t pid = getpid();

	log_notice("Started foreign key validation worker %d [%d]",
			   pid, getppid());

	if (!catalog_init_from_specs(specs))
	{
		log_error("Failed to open internal catalogs in foreign key "
				  "validation worker process, see above for details");
		return false;
	}

	bool stop = false;

	while (!stop)
	{
		QMessage mesg = { 0 };
		bool recv_ok = queue_receive(&(specs->fkValidateQueue), &mesg);

		if (asked_to_stop || asked_to_stop_fast || asked_to_quit)
		{
			log_error("Foreign key validation worker has been interrupted");
			(void) catalog_close_from_specs(specs);
			return false;
		}

		if (!recv_ok)
		{
			/* errors have already been logged */
			(void) catalog_close_from_specs(specs);
			return false;
		}

		switch (mesg.type)
		{
			case QMSG_TYPE_STOP:
			{
				stop = true;
				log_debug("Stop message received by foreign key "
						  "validation worker");
				break;
			}

			case QMSG_TYPE_FK_RELOID:
			{
				if (!fk_validate_table(specs, mesg.data.oid))
				{
					/* errors have already been logged */
					(void) catalog_close_from_specs(specs);
					return false;
				}
				break;
			}

			default:
			{
				log_error("Received unknown message type %ld on foreign key "
						  "validation queue %d",
						  mesg.type,
						  specs->fkValidateQueue.qId);
				break;
			}
		}
	}

	return catalog_close_from_specs(specs);
}


/*
 * fk_validate_table validates the deferred foreign keys of the given table
 * that are left to validate, one after the other. It returns false only on
 * internal errors.
 */
static bool
fk_validate_table(CopyDataSpec *specs, uint32_t reloid)
{
	DatabaseCatalog *sourceDB = &(specs->catalogs.source);

	uint32_t *oids = NULL;
	int count = 0;

	if (!catalog_list_fk_validation_pending_by_table(sourceDB,
													 reloid,
													 &oids,
													 &count))
	{
		log_error("Failed to list the foreign keys of table oid %u to "
				  "validate, see above for details",
				  reloid);
		return false;
	}

	bool success = true;

	for (int i = 0; success && i < count; i++)
	{
		success = fk_validate_constraint_by_oid(specs, oids[i]);
	}

	free(oids);

	return success;
}


/*
 * fk_validate_constraint_by_oid runs ALTER TABLE ... VALIDATE CONSTRAINT for
 * the given foreign key on its own target connection, and records the outcome
 * in our catalogs. It returns false only on internal errors.
 */
static bool
fk_validate_constraint_by_oid(CopyDataSpec *specs, uint32_t oid)
{
	DatabaseCatalog *sourceDB = &(specs->catalogs.source);
	SourceFKConstraint fk = { 0 };

	if (!catalog_lookup_s_fk_constraint_by_oid(sourceDB, &fk, oid))
	{
		log_error("Failed to lookup foreign key oid %u in internal catalogs, "
				  "see above for details",
				  oid);
		return false;
	}

	/* the definition is not needed here */
	free(fk.constraintDef);
	fk.constraintDef = NULL;

	/* conname and qname are stored already quoted */
	char command[BUFSIZE] = { 0 };

	sformat(command, sizeof(command),
			"ALTER TABLE ONLY %s VALIDATE CONSTRAINT %s",
			fk.qname,
			fk.conname);

	/* the process title is also our application_name on the target */
	char psTitle[BUFSIZE] = { 0 };
	sformat(psTitle, sizeof(psTitle), "pgcopydb: %s", command);
	(void) set_ps_title(psTitle);

	if (!summary_start_fk_validation(sourceDB, oid))
	{
		/* errors have already been logged */
		return false;
	}

	log_info("%s", command);

	instr_time startTime;
	INSTR_TIME_SET_CURRENT(startTime);

	PGSQL dst = { 0 };
	PGcancel *cancel = NULL;
	bool validated = false;

	/*
	 * Commit synchronously: once recorded as validated in our catalogs, the
	 * foreign key must not be found NOT VALID after a crash of the target.
	 */
	if (pgsql_init(&dst, specs->connStrings.target_pguri, PGSQL_CONN_TARGET) &&
		pgsql_set_gucs(&dst, dstSettings) &&
		pgsql_begin(&dst) &&
		pgsql_execute(&dst, "SET LOCAL search_path TO ''") &&
		pgsql_execute(&dst, "SET LOCAL synchronous_commit TO on"))
	{
		/*
		 * An interrupted query is only abandoned by the client, the server
		 * keeps running it: keep what is needed to cancel it.
		 */
		cancel = PQgetCancel(dst.connection);

		validated = pgsql_execute(&dst, command) && pgsql_commit(&dst);
	}

	char error[BUFSIZE] = { 0 };

	if (!validated)
	{
		const char *message =
			dst.connection != NULL ? PQerrorMessage(dst.connection) : NULL;

		sformat(error, sizeof(error), "%s: %s",
				IS_EMPTY_STRING_BUFFER(dst.sqlstate) ? "unknown" : dst.sqlstate,
				message != NULL && message[0] != '\0'
				? message
				: "failed to connect or run the command, see the logs");

		/* drop the trailing newline of the Postgres error message */
		size_t len = strlen(error);

		if (len > 0 && error[len - 1] == '\n')
		{
			error[len - 1] = '\0';
		}
	}

	if (dst.connection != NULL)
	{
		if (dst.connectionStatementType == PGSQL_CONNECTION_MULTI_STATEMENT)
		{
			(void) pgsql_rollback(&dst);
		}
		else
		{
			(void) pgsql_finish(&dst);
		}
	}

	/*
	 * An interrupted validation is cancelled on the target, so that it does
	 * not hold its lock until the scan is done, and retried on resume.
	 */
	if (!validated && (asked_to_stop || asked_to_stop_fast || asked_to_quit))
	{
		if (cancel != NULL)
		{
			char errbuf[256] = { 0 };

			if (!PQcancel(cancel, errbuf, sizeof(errbuf)))
			{
				log_warn("Failed to cancel the validation of foreign key %s "
						 "on %s: %s",
						 fk.conname, fk.qname, errbuf);
			}

			PQfreeCancel(cancel);
		}

		log_error("Validation of foreign key %s on %s has been interrupted",
				  fk.conname, fk.qname);
		return false;
	}

	if (cancel != NULL)
	{
		PQfreeCancel(cancel);
	}

	instr_time duration;
	INSTR_TIME_SET_CURRENT(duration);
	INSTR_TIME_SUBTRACT(duration, startTime);

	if (validated)
	{
		log_info("Validated foreign key %s on %s", fk.conname, fk.qname);
	}
	else
	{
		log_error("Failed to validate foreign key %s on %s, it is left "
				  "NOT VALID on the target: %s",
				  fk.conname, fk.qname, error);
	}

	return summary_finish_fk_validation(sourceDB,
										oid,
										INSTR_TIME_GET_MILLISEC(duration),
										validated
										? FK_VALIDATION_STATUS_VALIDATED
										: FK_VALIDATION_STATUS_FAILED,
										validated ? NULL : error);
}


/*
 * fk_validate_count counts the deferred foreign keys left to validate, and
 * the ones of those whose last validation failed.
 *
 * It uses its own SQLite connection: the specs might hold a connection that a
 * copy of the specs has closed already, see follow_reset_sequences.
 */
bool
fk_validate_count(CopyDataSpec *specs, int *pending, int *failed)
{
	DatabaseCatalog sourceDB = specs->catalogs.source;

	sourceDB.db = NULL;
	sourceDB.stmtCache = NULL;

	if (!catalog_open(&sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	bool counted = catalog_count_fk_validation(&sourceDB, pending, failed);

	return catalog_close(&sourceDB) && counted;
}
