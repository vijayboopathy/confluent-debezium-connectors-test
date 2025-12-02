## Replication slot status
```sql
slot_name   |  plugin  | slot_type | datoid | database | temporary | active | active_pid | xmin | catalog_xmin | restart_lsn | confirmed_flush_lsn | wal_status | safe_wal_size | two_phase | conflicting[27;5;106~---------------+----------+-----------+--------+----------+-----------+--------+------------+------+--------------+-------------+---------------------+------------+---------------+-----------+-------------[27;5;106~ debezium_slot | pgoutput | logical   |  16384 | testdb   | f         | t      |        406 |      |         1103 | 0/19C3118   | 0/19C3118           | reserved   |               | f         | f
```

## Connector offset
```json
{"offsets":[{"partition":{"server":"cdc"},"offset":{"transaction_id":null,"lsn_proc":27068176,"messageType":"UPDATE","lsn_commit":27068176,"lsn":27068176,"txId":1117,"ts_usec":1764653923373976}}]}
```

## Capture LSN
```sql
confirmed_flush_lsn
---------------------
 0/19D6478
(1 row)
```
