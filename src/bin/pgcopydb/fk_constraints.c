/*
 * src/bin/pgcopydb/fk_constraints.c
 *	 Implementation of a CLI to copy a database between two Postgres instances
 *
 * Foreign keys handled by pgcopydb itself, with --defer-validate-fks.
 */

#include <errno.h>
#include <inttypes.h>
#include <string.h>

#include "postgres_fe.h"
#include "pqexpbuffer.h"

#include "catalog.h"
#include "copydb.h"
#include "log.h"
#include "pgsql.h"
#include "schema.h"
#include "string_utils.h"

#define FK_STATUS_CREATED "created"
#define FK_STATUS_SOURCE_NOT_VALID "source_not_valid"
#define FK_STATUS_SKIPPED_OUT_OF_SCOPE "skipped_out_of_scope"

#define NOT_VALID_SUFFIX " NOT VALID"


typedef struct SourceFKConstraintArray
{
	int count;
	int capacity;
	SourceFKConstraint *array;  /* malloc'ed area */
} SourceFKConstraintArray;


/*
 * copydb_collect_fk_constraints_hook is an iterator callback that collects
 * the foreign keys in an array, taking ownership of their constraintDef.
 */
static bool
copydb_collect_fk_constraints_hook(void *ctx, SourceFKConstraint *fk)
{
	SourceFKConstraintArray *fkArray = (SourceFKConstraintArray *) ctx;

	if (fkArray->count >= fkArray->capacity)
	{
		int capacity = fkArray->capacity == 0 ? 16 : fkArray->capacity * 2;

		SourceFKConstraint *array =
			(SourceFKConstraint *) realloc(fkArray->array,
										   capacity * sizeof(SourceFKConstraint));

		if (array == NULL)
		{
			log_error(ALLOCATION_FAILED_ERROR);
			return false;
		}

		fkArray->array = array;
		fkArray->capacity = capacity;
	}

	fkArray->array[fkArray->count++] = *fk;

	/* the iterator must not release it now */
	fk->constraintDef = NULL;

	return true;
}


/*
 * stripNotValid removes a trailing " NOT VALID" from a constraint definition,
 * in place.
 */
static void
stripNotValid(char *constraintDef)
{
	size_t len = strlen(constraintDef);
	size_t suffixLen = strlen(NOT_VALID_SUFFIX);

	if (len >= suffixLen &&
		strcmp(constraintDef + len - suffixLen, NOT_VALID_SUFFIX) == 0)
	{
		constraintDef[len - suffixLen] = '\0';
	}
}


/*
 * copydb_target_fk_matches fetches the definition of the foreign key with the
 * same name on the target, and compares it to the source definition, ignoring
 * the NOT VALID property on both sides.
 */
static bool
copydb_target_fk_matches(PGSQL *dst, SourceFKConstraint *fk, bool *matches)
{
	SingleValueResultContext parseContext = { { 0 }, PGSQL_RESULT_STRING, false };

	char *sql =
		"select pg_get_constraintdef(c.oid) "
		"  from pg_constraint c "
		" where c.conrelid = $1::regclass "
		"   and format('%I', c.conname) = $2 "
		"   and c.contype = 'f'";

	int paramCount = 2;
	Oid paramTypes[2] = { TEXTOID, TEXTOID };
	const char *paramValues[2] = { fk->qname, fk->conname };

	*matches = false;

	/* same search_path as when the definitions were rendered on the source */
	bool fetched = pgsql_begin(dst) &&
				   pgsql_execute(dst, "SET LOCAL search_path TO ''") &&
				   pgsql_execute_with_params(dst, sql,
											 paramCount, paramTypes, paramValues,
											 &parseContext,
											 &parseSingleValueResult);

	if (dst->connection != NULL)
	{
		(void) pgsql_rollback(dst);
	}

	if (!fetched)
	{
		log_error("Failed to fetch the definition of foreign key %s on %s "
				  "from the target database",
				  fk->conname, fk->qname);
		return false;
	}

	if (!parseContext.parsedOk || parseContext.strVal == NULL)
	{
		log_warn("Foreign key %s on %s already exists on the target "
				 "database, and is not a foreign key",
				 fk->conname, fk->qname);
		return true;
	}

	char *targetDef = parseContext.strVal;
	char *sourceDef = strdup(fk->constraintDef);

	if (sourceDef == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		free(targetDef);
		return false;
	}

	stripNotValid(targetDef);
	stripNotValid(sourceDef);

	*matches = streq(targetDef, sourceDef);

	if (!*matches)
	{
		log_error("Foreign key %s on %s already exists on the target "
				  "database with a different definition",
				  fk->conname, fk->qname);
		log_error("Source: %s", sourceDef);
		log_error("Target: %s", targetDef);
	}

	free(targetDef);
	free(sourceDef);

	return true;
}


/*
 * copydb_create_fk_constraint creates one foreign key on the target, in its
 * own transaction, and records it in the fk_constraint_summary catalog.
 */
static bool
copydb_create_fk_constraint(CopyDataSpec *specs, PGSQL *dst, SourceFKConstraint *fk)
{
	DatabaseCatalog *sourceDB = &(specs->catalogs.source);

	char *status =
		fk->convalidated ? FK_STATUS_CREATED : FK_STATUS_SOURCE_NOT_VALID;

	/*
	 * The scope is decided by the source and its filters, not by the errors
	 * of the target: a missing table that should be there is a failure. A
	 * foreign key out of scope is left to pg_restore, as without
	 * --defer-validate-fks, and only recorded here.
	 */
	if (!fk->inScope)
	{
		log_notice("Leaving foreign key %s on %s to pg_restore: the "
				   "referenced table is not part of the copy (filtered out)",
				   fk->conname, fk->qname);

		return summary_add_fk_constraint(sourceDB, fk, "") &&
			   summary_finish_fk_constraint(sourceDB, fk, 0,
											FK_STATUS_SKIPPED_OUT_OF_SCOPE);
	}

	/*
	 * pg_get_constraintdef() already ends with NOT VALID when the foreign key
	 * is not validated on the source.
	 */
	PQExpBuffer command = createPQExpBuffer();

	appendPQExpBuffer(command,
					  "ALTER TABLE ONLY %s ADD CONSTRAINT %s %s%s",
					  fk->qname,
					  fk->conname,
					  fk->constraintDef,
					  fk->convalidated ? NOT_VALID_SUFFIX : "");

	if (PQExpBufferBroken(command))
	{
		log_error("Failed to prepare the command for foreign key %s: "
				  "out of memory", fk->conname);
		destroyPQExpBuffer(command);
		return false;
	}

	if (!summary_add_fk_constraint(sourceDB, fk, command->data))
	{
		/* errors have already been logged */
		destroyPQExpBuffer(command);
		return false;
	}

	instr_time startTime;
	INSTR_TIME_SET_CURRENT(startTime);

	log_info("%s", command->data);

	bool created = pgsql_begin(dst) &&
				   pgsql_execute(dst, "SET LOCAL search_path TO ''") &&
				   pgsql_execute(dst, command->data);

	destroyPQExpBuffer(command);

	if (created)
	{
		if (!pgsql_commit(dst))
		{
			/* errors have already been logged */
			return false;
		}
	}
	else
	{
		char sqlstate[SQLSTATE_LENGTH] = { 0 };

		strlcpy(sqlstate, dst->sqlstate, sizeof(sqlstate));

		/* the connection is closed already when it could not be opened */
		if (dst->connection != NULL)
		{
			(void) pgsql_rollback(dst);
		}

		if (streq(sqlstate, STR_ERRCODE_DUPLICATE_OBJECT))
		{
			bool matches = false;

			/* the target connection was closed by the rollback */
			if (!copydb_target_fk_matches(dst, fk, &matches) || !matches)
			{
				return false;
			}

			log_notice("Foreign key %s on %s already exists on the target "
					   "database", fk->conname, fk->qname);
		}
		else
		{
			log_error("Failed to create foreign key %s on %s",
					  fk->conname, fk->qname);
			return false;
		}
	}

	instr_time duration;
	INSTR_TIME_SET_CURRENT(duration);
	INSTR_TIME_SUBTRACT(duration, startTime);

	return summary_finish_fk_constraint(sourceDB,
										fk,
										INSTR_TIME_GET_MILLISEC(duration),
										status);
}


/*
 * copydb_create_fk_constraints creates on the target database the foreign
 * keys that --defer-validate-fks left out of pg_restore, as NOT VALID when
 * they are valid on the source.
 */
bool
copydb_create_fk_constraints(CopyDataSpec *specs)
{
	DatabaseCatalog *sourceDB = &(specs->catalogs.source);

	SourceFKConstraintArray fkArray = { 0 };

	if (!catalog_iter_s_fk_constraint(sourceDB,
									  &fkArray,
									  &copydb_collect_fk_constraints_hook))
	{
		/* errors have already been logged */
		return false;
	}

	if (fkArray.count == 0)
	{
		log_info("No foreign keys to create");
		return true;
	}

	log_info("Creating %d foreign keys NOT VALID (--defer-validate-fks)",
			 fkArray.count);

	PGSQL dst = { 0 };

	if (!pgsql_init(&dst, specs->connStrings.target_pguri, PGSQL_CONN_TARGET))
	{
		/* errors have already been logged */
		return false;
	}

	bool success = true;

	for (int i = 0; i < fkArray.count && success; i++)
	{
		SourceFKConstraint *fk = &(fkArray.array[i]);

		bool done = false;

		if (!summary_lookup_fk_constraint(sourceDB, fk->oid, &done))
		{
			/* errors have already been logged */
			success = false;
		}
		else if (done)
		{
			log_notice("Skipping foreign key %s on %s, done on a previous run",
					   fk->conname, fk->qname);
		}
		else
		{
			success = copydb_create_fk_constraint(specs, &dst, fk);
		}
	}

	for (int i = 0; i < fkArray.count; i++)
	{
		free(fkArray.array[i].constraintDef);
	}

	free(fkArray.array);
	(void) pgsql_finish(&dst);

	return success;
}
