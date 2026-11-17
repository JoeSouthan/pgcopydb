FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./fail-commit.gdb ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
