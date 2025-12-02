## Replication slot status
```sql
slot_name   |  plugin  | slot_type | datoid | database | temporary | active | active_pid | xmin | catalog_xmin | restart_lsn | confirmed_flush_lsn | wal_status | safe_wal_size | two_phase | conflicting
---------------+----------+-----------+--------+----------+-----------+--------+------------+------+--------------+-------------+---------------------+------------+---------------+-----------+-------------
 debezium_slot | pgoutput | logical   |  16384 | testdb   | f         | t      |        151 |      |          896 | 0/1993928   | 0/1993928           | reserved   |               | f         | f
(1 row)
```

## Connector offset
```json
{"offsets":[{"partition":{"server":"cdc"},"offset":{"transaction_id":null,"lsn_proc":26818856,"messageType":"UPDATE","lsn_commit":26818856,"lsn":26818856,"txId":895,"ts_usec":1764665965091476}}]}
```

## LSN
```sql

 confirmed_flush_lsn
---------------------
 0/1993928
(1 row)
```
