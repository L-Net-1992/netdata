// SPDX-License-Identifier: GPL-3.0-or-later

#include "dyncfg-internals.h"
#include "dyncfg.h"

static int dyncfg_tree_compar(const void *a, const void *b) {
    const DICTIONARY_ITEM *item1 = *(const DICTIONARY_ITEM **)a;
    const DICTIONARY_ITEM *item2 = *(const DICTIONARY_ITEM **)b;

    DYNCFG *df1 = dictionary_acquired_item_value(item1);
    DYNCFG *df2 = dictionary_acquired_item_value(item2);

    int rc = string_cmp(df1->path, df2->path);
    if(rc == 0)
        rc = strcmp(dictionary_acquired_item_name(item1), dictionary_acquired_item_name(item2));

    return rc;
}

static void dyncfg_to_json(DYNCFG *df, const char *id, BUFFER *wb) {
    buffer_json_member_add_object(wb, id);
    {
        buffer_json_member_add_string(wb, "type", dyncfg_id2type(df->type));
        buffer_json_member_add_string(wb, "status", dyncfg_id2status(df->status));
        dyncfg_cmds2json_array(df->cmds, "cmds", wb);
        buffer_json_member_add_string(wb, "source_type", dyncfg_id2source_type(df->source_type));
        buffer_json_member_add_string(wb, "source", string2str(df->source));
        buffer_json_member_add_boolean(wb, "sync", df->sync);
        buffer_json_member_add_boolean(wb, "user_disabled", df->user_disabled);
        buffer_json_member_add_boolean(wb, "restart_required", df->restart_required);
        buffer_json_member_add_boolean(wb, "plugin_rejected", df->restart_required);
        buffer_json_member_add_object(wb, "payload");
        {
            if (df->payload && buffer_strlen(df->payload)) {
                buffer_json_member_add_boolean(wb, "available", true);
                buffer_json_member_add_string(wb, "content_type", content_type_id2string(df->payload->content_type));
                buffer_json_member_add_uint64(wb, "content_length", df->payload->len);
            } else
                buffer_json_member_add_boolean(wb, "available", false);
        }
        buffer_json_object_close(wb); // payload
        buffer_json_member_add_uint64(wb, "saves", df->saves);
        buffer_json_member_add_uint64(wb, "created_ut", df->created_ut);
        buffer_json_member_add_uint64(wb, "modified_ut", df->modified_ut);
    }
    buffer_json_object_close(wb);
}

static void dyncfg_tree_for_host(RRDHOST *host, BUFFER *wb, const char *parent, const char *id) {
    size_t entries = dictionary_entries(dyncfg_globals.nodes);
    size_t used = 0;
    const DICTIONARY_ITEM *items[entries];
    size_t restart_required = 0, plugin_rejected = 0, status_incomplete = 0, status_failed = 0;

    size_t parent_len = strlen(parent);
    DYNCFG *df;
    dfe_start_read(dyncfg_globals.nodes, df) {
        if(!df->host) {
            if(uuid_memcmp(&df->host_uuid, &host->host_uuid) == 0)
                df->host = host;
        }

        if(df->host != host || strncmp(string2str(df->path), parent, parent_len) != 0)
            continue;

        if(!rrd_function_available(host, string2str(df->function)))
            df->status = DYNCFG_STATUS_ORPHAN;

        items[used++] = dictionary_acquired_item_dup(dyncfg_globals.nodes, df_dfe.item);
    }
    dfe_done(df);

    qsort(items, used, sizeof(const DICTIONARY_ITEM *), dyncfg_tree_compar);

    buffer_flush(wb);
    buffer_json_initialize(wb, "\"", "\"", 0, true, BUFFER_JSON_OPTIONS_MINIFY);

    buffer_json_member_add_uint64(wb, "version", 1);

    buffer_json_member_add_object(wb, "tree");
    {
        STRING *last_path = NULL;
        for (size_t i = 0; i < used; i++) {
            df = dictionary_acquired_item_value(items[i]);
            if (df->path != last_path) {
                last_path = df->path;

                if (i)
                    buffer_json_object_close(wb);

                buffer_json_member_add_object(wb, string2str(last_path));
            }

            dyncfg_to_json(df, dictionary_acquired_item_name(items[i]), wb);

            if(df->status != DYNCFG_STATUS_ORPHAN) {
                if (df->restart_required)
                    restart_required++;

                if (df->plugin_rejected)
                    plugin_rejected++;

                if (df->status == DYNCFG_STATUS_FAILED)
                    status_failed++;

                if (df->status == DYNCFG_STATUS_INCOMPLETE)
                    status_incomplete++;
            }
        }

        if (used)
            buffer_json_object_close(wb);
    }
    buffer_json_object_close(wb); // tree

    buffer_json_member_add_object(wb, "attention");
    {
        buffer_json_member_add_boolean(wb, "degraded", restart_required + plugin_rejected + status_failed + status_incomplete > 0);
        buffer_json_member_add_uint64(wb, "restart_required", restart_required);
        buffer_json_member_add_uint64(wb, "plugin_rejected", plugin_rejected);
        buffer_json_member_add_uint64(wb, "status_failed", status_failed);
        buffer_json_member_add_uint64(wb, "status_incomplete", status_incomplete);
    }
    buffer_json_object_close(wb); // attention

    buffer_json_agents_v2(wb, NULL, 0, false, false);

    buffer_json_finalize(wb);

    for(size_t i = 0; i < used ;i++)
        dictionary_acquired_item_release(dyncfg_globals.nodes, items[i]);
}

static int dyncfg_config_execute_cb(struct rrd_function_execute *rfe, void *data) {
    RRDHOST *host = data;
    int code;

    char buf[strlen(rfe->function) + 1];
    memcpy(buf, rfe->function, sizeof(buf));

    char *words[MAX_FUNCTION_PARAMETERS];    // an array of pointers for the words in this line
    size_t num_words = quoted_strings_splitter_pluginsd(buf, words, MAX_FUNCTION_PARAMETERS);

    const char *config = get_word(words, num_words, 0);
    const char *action = get_word(words, num_words, 1);
    const char *path = get_word(words, num_words, 2);
    const char *id = get_word(words, num_words, 3);

    if(!config || !*config || strcmp(config, PLUGINSD_FUNCTION_CONFIG) != 0) {
        char *msg = "invalid function call, expected: config";
        nd_log(NDLS_DAEMON, NDLP_ERR, "DYNCFG TREE: function call '%s': %s", rfe->function, msg);
        code = dyncfg_default_response(rfe->result.wb, HTTP_RESP_BAD_REQUEST, msg);
        goto cleanup;
    }

    if(!action || !*action) {
        char *msg = "invalid function call, expected: config tree";
        nd_log(NDLS_DAEMON, NDLP_ERR, "DYNCFG TREE: function call '%s': %s", rfe->function, msg);
        code = dyncfg_default_response(rfe->result.wb, HTTP_RESP_BAD_REQUEST, msg);
        goto cleanup;
    }

    if(strcmp(action, "tree") == 0) {
        if(!path || !*path)
            path = "/";

        if(!id || !*id)
            id = NULL;
        else if(!dyncfg_is_valid_id(id)) {
            char *msg = "invalid id given";
            nd_log(NDLS_DAEMON, NDLP_ERR, "DYNCFG TREE: function call '%s': %s", rfe->function, msg);
            code = dyncfg_default_response(rfe->result.wb, HTTP_RESP_BAD_REQUEST, msg);
            goto cleanup;
        }

        code = HTTP_RESP_OK;
        dyncfg_tree_for_host(host, rfe->result.wb, path, id);
    }
    else {
        code = HTTP_RESP_NOT_FOUND;
        nd_log(NDLS_DAEMON, NDLP_ERR, "DYNCFG: unknown config id '%s' in call: '%s'. This can happen if the plugin that registered the dynamic configuration is not running now.", action, rfe->function);
        rrd_call_function_error(rfe->result.wb, "unknown config id given", code);
    }

cleanup:
    if(rfe->result.cb)
        rfe->result.cb(rfe->result.wb, code, rfe->result.data);

    return code;
}

// ----------------------------------------------------------------------------
// this adds a 'config' function to all leaf nodes (localhost and virtual nodes)
// which is used to serve the tree and act as a catch-all for all config calls
// for which there is no id overloaded.

void dyncfg_host_init(RRDHOST *host) {
    rrd_function_add(host, NULL, PLUGINSD_FUNCTION_CONFIG, 120,
                     1000, "Dynamic configuration", "config",
                     HTTP_ACCESS_ADMIN,
                     true, dyncfg_config_execute_cb, host);
}
