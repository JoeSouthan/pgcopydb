FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./fixture.sql ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
