/*
 * src/bin/pgcopydb/fk_validate.h
 *	 Validation of the foreign keys deferred with --defer-validate-fks
 */

#ifndef FK_VALIDATE_H
#define FK_VALIDATE_H

#include <stdbool.h>
#include <sys/types.h>

#include "copydb.h"

bool fk_validate_start_supervisor(CopyDataSpec *specs, pid_t *pidOut);
bool fk_validate_supervisor(CopyDataSpec *specs);
bool fk_validate_worker(CopyDataSpec *specs);
bool fk_validate_count(CopyDataSpec *specs, int *pending, int *failed);

#endif /* FK_VALIDATE_H */
