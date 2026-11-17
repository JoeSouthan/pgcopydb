set pagination off
set confirm off
python
expected = gdb.parse_and_eval("$expected_lsn").string()


class FailCommit(gdb.Breakpoint):
    """Makes the COMMIT that follows the origin setup at the expected LSN fail.

    The setup has been sent by then: the server aborts the transaction after
    pg_replication_origin_xact_setup(), as when a COMMIT fails.
    """

    origin_lsn = None
    failed = False

    def stop(self):
        if self.failed:
            return False
        sql = gdb.parse_and_eval("sql").string()
        if "pg_replication_origin_xact_setup" in sql:
            self.origin_lsn = gdb.parse_and_eval("paramValues[0]").string()
        elif sql == "COMMIT" and self.origin_lsn == expected:
            # the string literal is shared: every later COMMIT fails too
            gdb.execute("set var *(char *) sql = 'X'")
            self.failed = True
            gdb.write(f"Turned the COMMIT at {expected} into XOMMIT\n")
        return False


commit = FailCommit("pgsql_execute_with_params")
end
run
python
if not commit.failed:
    raise gdb.GdbError("apply did not send the COMMIT at the expected LSN")
end
quit 0
