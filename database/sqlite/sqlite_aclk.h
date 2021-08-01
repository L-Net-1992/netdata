// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef NETDATA_SQLITE_ACLK_H
#define NETDATA_SQLITE_ACLK_H

#include "sqlite3.h"

#include "../../aclk/schema-wrappers/chart_stream.h"

#ifndef ACLK_MAX_CHART_BATCH
#define ACLK_MAX_CHART_BATCH    (20)
#endif
#ifndef ACLK_MAX_CHART_BATCH_COUNT
#define ACLK_MAX_CHART_BATCH_COUNT (5)
#endif
#define ACLK_MAX_ALERT_UPDATES  (5)
#define ACLK_SYNC_RETRY_COUNT   "10"
#define ACLK_DATABASE_CLEANUP_FIRST  (60)
#define ACLK_DATABASE_CLEANUP_INTERVAL (3600)
#define ACLK_DELETE_ACK_INTERNAL (600)        // ACKed messages from cloud can be deleted after (seconds)

struct aclk_completion {
    uv_mutex_t mutex;
    uv_cond_t cond;
    volatile unsigned completed;
};

static inline void init_aclk_completion(struct aclk_completion *p)
{
    p->completed = 0;
    fatal_assert(0 == uv_cond_init(&p->cond));
    fatal_assert(0 == uv_mutex_init(&p->mutex));
}

static inline void destroy_aclk_completion(struct aclk_completion *p)
{
    uv_cond_destroy(&p->cond);
    uv_mutex_destroy(&p->mutex);
}

static inline void wait_for_aclk_completion(struct aclk_completion *p)
{
    uv_mutex_lock(&p->mutex);
    while (0 == p->completed) {
        uv_cond_wait(&p->cond, &p->mutex);
    }
    fatal_assert(1 == p->completed);
    uv_mutex_unlock(&p->mutex);
}

static inline void aclk_complete(struct aclk_completion *p)
{
    uv_mutex_lock(&p->mutex);
    p->completed = 1;
    uv_mutex_unlock(&p->mutex);
    uv_cond_broadcast(&p->cond);
}

extern uv_mutex_t aclk_async_lock;

extern int aclk_architecture;

static inline void uuid_unparse_lower_fix(uuid_t *uuid, char *out)
{
    uuid_unparse_lower(*uuid, out);
    out[8] = '_';
    out[13] = '_';
    out[18] = '_';
    out[23] = '_';
}

static inline char *get_str_from_uuid(uuid_t *uuid)
{
    char uuid_str[GUID_LEN + 1];
    if (unlikely(!uuid)) {
        uuid_t zero_uuid;
        uuid_clear(zero_uuid);
        uuid_unparse_lower(zero_uuid, uuid_str);
    }
    else
        uuid_unparse_lower(*uuid, uuid_str);
    return strdupz(uuid_str);
}

#define TABLE_ACLK_CHART "CREATE TABLE IF NOT EXISTS aclk_chart_%s (sequence_id INTEGER PRIMARY KEY AUTOINCREMENT, " \
        "date_created, date_updated, date_submitted, status, uuid, type, unique_id, " \
        "update_count default 1, unique(uuid, status));"

#define TABLE_ACLK_CHART_PAYLOAD "CREATE TABLE IF NOT EXISTS aclk_chart_payload_%s (unique_id BLOB PRIMARY KEY, " \
        "uuid, claim_id, type, date_created, payload);"

#define TABLE_ACLK_CHART_LATEST "CREATE TABLE IF NOT EXISTS aclk_chart_latest_%s (uuid BLOB PRIMARY KEY, " \
        "unique_id, date_submitted);"

#define TRIGGER_ACLK_CHART_PAYLOAD "CREATE TRIGGER IF NOT EXISTS aclk_tr_chart_payload_%s " \
        "after insert on aclk_chart_payload_%s " \
        "begin insert into aclk_chart_%s (uuid, unique_id, type, status, date_created) values " \
        " (new.uuid, new.unique_id, new.type, 'pending', strftime('%%s')) on conflict(uuid, status) " \
        " do update set unique_id = new.unique_id, update_count = update_count + 1; " \
        "end;"

#define TABLE_ACLK_ALERT "CREATE TABLE IF NOT EXISTS aclk_alert_%s (sequence_id INTEGER PRIMARY KEY AUTOINCREMENT, " \
        "alert_unique_id, date_created, date_submitted, " \
        "unique(alert_unique_id)); " \
        "insert into aclk_alert_%s (alert_unique_id, date_created) " \
        "select unique_id alert_unique_id, strftime('%%s') date_created from health_log_%s where new_status <> 0 order by unique_id asc;"

#define INDEX_ACLK_CHART "CREATE INDEX IF NOT EXISTS aclk_chart_index_%s ON aclk_chart_%s (unique_id);"

#define INDEX_ACLK_CHART_LATEST  "CREATE INDEX IF NOT EXISTS aclk_chart_latest_index_%s ON aclk_chart_latest_%s (unique_id);"

#define INDEX_ACLK_ALERT "CREATE INDEX IF NOT EXISTS aclk_alert_index_%s ON aclk_alert_%s (alert_unique_id);"

enum aclk_database_opcode {
    ACLK_DATABASE_NOOP = 0,
    ACLK_DATABASE_ADD_ALERT,
    ACLK_DATABASE_ADD_CHART,
    ACLK_DATABASE_ADD_DIMENSION,
    ACLK_DATABASE_ALARM_HEALTH_LOG,
    ACLK_DATABASE_CHART_ACK,
    ACLK_DATABASE_CHECK,
    ACLK_DATABASE_CHECK_ROTATION,
    ACLK_DATABASE_CLEANUP,
    ACLK_DATABASE_DEDUP_CHART,
    ACLK_DATABASE_DELETE_HOST,
    ACLK_DATABASE_NODE_INFO,
    ACLK_DATABASE_PUSH_ALERT,
    ACLK_DATABASE_PUSH_ALERT_CONFIG,
    ACLK_DATABASE_PUSH_CHART,
    ACLK_DATABASE_PUSH_CHART_CONFIG,
    ACLK_DATABASE_RESET_CHART,
    ACLK_DATABASE_RESET_NODE,
    ACLK_DATABASE_SHUTDOWN,
    ACLK_DATABASE_STATUS_CHART,
    ACLK_DATABASE_SYNC_CHART_SEQ,
    ACLK_DATABASE_TIMER,
    ACLK_DATABASE_UPD_STATS,
    ACLK_DATABASE_MAX_OPCODE
};

struct aclk_chart_payload_t {
    long sequence_id;
    long last_sequence_id;
    char *payload;
    struct aclk_chart_payload_t *next;
};


struct aclk_database_cmd {
    enum aclk_database_opcode opcode;
    void *data;
    void *data_param;
    int count;
    uint64_t param1;
    struct aclk_completion *completion;
};

#define ACLK_DATABASE_CMD_Q_MAX_SIZE (2048)

struct aclk_database_cmdqueue {
    unsigned head, tail;
    struct aclk_database_cmd cmd_array[ACLK_DATABASE_CMD_Q_MAX_SIZE];
};

struct aclk_database_worker_config {
    uv_thread_t thread;
    char uuid_str[GUID_LEN + 1];
    char node_id[GUID_LEN + 1];
    char host_guid[GUID_LEN + 1];
    uint64_t chart_sequence_id;     // last chart_sequence_id
    time_t chart_timestamp;         // last chart timestamp
    time_t cleanup_after;           // Start a cleanup after this timestamp
    time_t startup_time;           // When the sync thread started
    uint64_t batch_id;    // batch id to use
    uint64_t alerts_batch_id; // batch id for alerts to use
    uint64_t alerts_start_seq_id; // cloud has asked to start streaming from
    uint64_t alert_sequence_id; // last alert sequence_id
    uv_loop_t *loop;
    RRDHOST *host;
    uv_async_t async;
    /* FIFO command queue */
    uv_mutex_t cmd_mutex;
    uv_cond_t cmd_cond;
    volatile unsigned queue_size;
    struct aclk_database_cmdqueue cmd_queue;
    int error;
    int chart_updates;
    int alert_updates;
    time_t batch_created;
    struct aclk_database_worker_config  *next;
//    RRDSET *chart_add;      // Chart events added
//    RRDSET *chart_snd;      // Chart events sent
//    RRDSET *alert_add;      // Alert events added
//    RRDSET *alert_snd;      // Alert events sent
};

static inline RRDHOST *find_host_by_node_id(char *node_id)
{
    uuid_t node_uuid;
    if (unlikely(!node_id))
        return NULL;

    uuid_parse(node_id, node_uuid);

    RRDHOST *host = localhost;
    while(host) {
        if (host->node_id && !(uuid_compare(*host->node_id, node_uuid)))
            return host;
        host = host->next;
    }
    return NULL;
}


extern sqlite3 *db_meta;

extern void aclk_database_enq_cmd(struct aclk_database_worker_config *wc, struct aclk_database_cmd *cmd);
extern int aclk_database_enq_cmd_noblock(struct aclk_database_worker_config *wc, struct aclk_database_cmd *cmd);
extern void sql_create_aclk_table(RRDHOST *host, uuid_t *host_uuid, uuid_t *node_id);
extern void aclk_set_architecture(int mode);
void sql_aclk_sync_init(void);
void sql_maint_aclk_sync_database(struct aclk_database_worker_config *wc, struct aclk_database_cmd cmd);
void sql_delete_aclk_table_list(struct aclk_database_worker_config *wc, struct aclk_database_cmd cmd);
void sql_drop_host_aclk_table_list(uuid_t *host_uuid);
void sql_check_aclk_table_list(struct aclk_database_worker_config *wc);
//int is_host_available(uuid_t *host_id);
#endif //NETDATA_SQLITE_ACLK_H
