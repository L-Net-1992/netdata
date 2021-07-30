// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef NETDATA_SQLITE_HEALTH_H
#define NETDATA_SQLITE_HEALTH_H
#include "../../daemon/common.h"
#include "sqlite3.h"

extern void sql_health_alarm_log_load(RRDHOST *host);
extern int sql_create_health_log_table(RRDHOST *host);
extern void sql_health_alarm_log_update(RRDHOST *host, ALARM_ENTRY *ae);
extern void sql_health_alarm_log_insert(RRDHOST *host, ALARM_ENTRY *ae);
extern void sql_health_alarm_log_save(RRDHOST *host, ALARM_ENTRY *ae);
extern void sql_health_alarm_log_select_all(BUFFER *wb, RRDHOST *host);
extern void sql_health_alarm_log_cleanup(RRDHOST *host);

#endif //NETDATA_SQLITE_HEALTH_H
