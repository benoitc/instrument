/* Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 *
 * This NIF implements the erl_tracer behavior for distributed trace event
 * handling. It hashes tracee pids to distribute events across a pool of
 * worker processes, avoiding the single-process bottleneck of seq_trace.
 *
 * Reference: https://www.erlang.org/doc/apps/erts/erl_tracer.html
 */

#include "erl_nif.h"

/*
 * enabled/3 - Check if tracing is enabled for the given tracee.
 *
 * TraceTag: atom() - the type of trace event (or trace_status for validation)
 * TracerState: #{pool_size => N, workers => #{0 => Pid1, ...}, label => Label}
 * Tracee: pid() | port() | undefined (for seq_trace)
 *
 * Returns: trace | discard | remove
 *
 * This is called before trace/5 to determine if we should trace.
 * Must be fast and free of side effects.
 */
static ERL_NIF_TERM
enabled(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    ERL_NIF_TERM trace_tag = argv[0];
    ERL_NIF_TERM tracer_state = argv[1];

    /* Handle trace_status - verify tracer is still valid */
    if (enif_is_atom(env, trace_tag)) {
        char tag_str[64];
        if (enif_get_atom(env, trace_tag, tag_str, sizeof(tag_str), ERL_NIF_LATIN1)) {
            if (strcmp(tag_str, "trace_status") == 0) {
                /* Check if pool is still valid */
                ERL_NIF_TERM pool_size_term;
                if (!enif_get_map_value(env, tracer_state,
                        enif_make_atom(env, "pool_size"), &pool_size_term)) {
                    return enif_make_atom(env, "remove");
                }
                unsigned int pool_size;
                if (!enif_get_uint(env, pool_size_term, &pool_size) || pool_size == 0) {
                    return enif_make_atom(env, "remove");
                }
                return enif_make_atom(env, "trace");
            }
        }
    }

    /* Always enable tracing for other tags */
    return enif_make_atom(env, "trace");
}

/*
 * enabled_send/3 - Check if send tracing is enabled.
 */
static ERL_NIF_TERM
enabled_send(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "trace");
}

/*
 * enabled_receive/3 - Check if receive tracing is enabled.
 */
static ERL_NIF_TERM
enabled_receive(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "trace");
}

/*
 * enabled_spawn/3 - Check if spawn tracing is enabled.
 */
static ERL_NIF_TERM
enabled_spawn(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "trace");
}

/*
 * enabled_procs/3 - Check if process tracing is enabled.
 */
static ERL_NIF_TERM
enabled_procs(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "trace");
}

/*
 * enabled_running_procs/3 - Check if running_procs tracing is enabled.
 */
static ERL_NIF_TERM
enabled_running_procs(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    /* Disable running_procs to reduce noise */
    return enif_make_atom(env, "discard");
}

/*
 * enabled_call/3 - Check if call tracing is enabled.
 */
static ERL_NIF_TERM
enabled_call(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    /* Disable call tracing - too much overhead for flight recorder */
    return enif_make_atom(env, "discard");
}

/*
 * enabled_garbage_collection/3 - Check if GC tracing is enabled.
 */
static ERL_NIF_TERM
enabled_garbage_collection(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    /* Disable GC tracing to reduce noise */
    return enif_make_atom(env, "discard");
}

/*
 * trace/5 - Handle a trace event by distributing to worker pool.
 *
 * TraceTag: atom() - send | 'receive' | spawn | exit | etc.
 * TracerState: #{pool_size => N, workers => #{0 => Pid1, ...}, label => Label}
 * Tracee: pid() - the traced process
 * TraceTerm: term() - the trace data (e.g., message for send/receive)
 * Opts: map() - #{extra => Extra, timestamp => TS, ...}
 *
 * The function hashes the tracee pid to select a worker, then sends:
 * {trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp}
 */
static ERL_NIF_TERM
trace(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;

    ERL_NIF_TERM trace_tag = argv[0];
    ERL_NIF_TERM tracer_state = argv[1];
    ERL_NIF_TERM tracee = argv[2];
    ERL_NIF_TERM trace_term = argv[3];
    ERL_NIF_TERM opts = argv[4];

    /* Get pool_size from TracerState */
    ERL_NIF_TERM pool_size_term;
    if (!enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "pool_size"), &pool_size_term)) {
        return enif_make_atom(env, "ok");
    }

    unsigned int pool_size;
    if (!enif_get_uint(env, pool_size_term, &pool_size) || pool_size == 0) {
        return enif_make_atom(env, "ok");
    }

    /* Get workers map from TracerState */
    ERL_NIF_TERM workers_term;
    if (!enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "workers"), &workers_term)) {
        return enif_make_atom(env, "ok");
    }

    /* Get label from TracerState */
    ERL_NIF_TERM label_term;
    if (!enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "label"), &label_term)) {
        label_term = enif_make_int(env, 0);
    }

    /* Hash tracee pid to select worker */
    ErlNifUInt64 hash = enif_hash(ERL_NIF_INTERNAL_HASH, tracee, 0);
    unsigned int worker_idx = hash % pool_size;

    /* Get worker pid from workers map */
    ERL_NIF_TERM worker_idx_term = enif_make_uint(env, worker_idx);
    ERL_NIF_TERM worker_pid_term;
    if (!enif_get_map_value(env, workers_term, worker_idx_term, &worker_pid_term)) {
        return enif_make_atom(env, "ok");
    }

    ErlNifPid worker_pid;
    if (!enif_get_local_pid(env, worker_pid_term, &worker_pid)) {
        return enif_make_atom(env, "ok");
    }

    /* Get current timestamp */
    ErlNifTime timestamp = enif_monotonic_time(ERL_NIF_NSEC);
    ERL_NIF_TERM timestamp_term = enif_make_int64(env, timestamp);

    /* Build trace message: {trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp} */
    ERL_NIF_TERM trace_atom = enif_make_atom(env, "trace");
    ERL_NIF_TERM trace_msg = enif_make_tuple7(env,
        trace_atom,
        tracee,
        trace_tag,
        trace_term,
        opts,
        label_term,
        timestamp_term
    );

    /* Send to worker - do not send to tracee to avoid infinite recursion! */
    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM copied_msg = enif_make_copy(msg_env, trace_msg);
    enif_send(env, &worker_pid, msg_env, copied_msg);
    enif_free_env(msg_env);

    return enif_make_atom(env, "ok");
}

/*
 * trace_send/5 - Handle send trace event.
 * TraceTerm: the message being sent
 * Opts: #{extra => Recipient}
 */
static ERL_NIF_TERM
trace_send(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    return trace(env, argc, argv);
}

/*
 * trace_receive/5 - Handle receive trace event.
 * TraceTerm: the message being received
 * Opts: #{}
 */
static ERL_NIF_TERM
trace_receive(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    return trace(env, argc, argv);
}

/*
 * trace_spawn/5 - Handle spawn trace event.
 * TraceTerm: the spawned pid
 * Opts: #{extra => {M, F, A}}
 */
static ERL_NIF_TERM
trace_spawn(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    return trace(env, argc, argv);
}

/*
 * trace_procs/5 - Handle process trace event (link, unlink, exit, etc.)
 */
static ERL_NIF_TERM
trace_procs(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    return trace(env, argc, argv);
}

static ErlNifFunc nif_funcs[] = {
    /* erl_tracer behavior callbacks - required */
    {"enabled", 3, enabled, 0},
    {"trace", 5, trace, 0},

    /* Specialized enabled callbacks - optional, improves performance */
    {"enabled_send", 3, enabled_send, 0},
    {"enabled_receive", 3, enabled_receive, 0},
    {"enabled_spawn", 3, enabled_spawn, 0},
    {"enabled_procs", 3, enabled_procs, 0},
    {"enabled_running_procs", 3, enabled_running_procs, 0},
    {"enabled_call", 3, enabled_call, 0},
    {"enabled_garbage_collection", 3, enabled_garbage_collection, 0},

    /* Specialized trace callbacks - optional */
    {"trace_send", 5, trace_send, 0},
    {"trace_receive", 5, trace_receive, 0},
    {"trace_spawn", 5, trace_spawn, 0},
    {"trace_procs", 5, trace_procs, 0}
};

static void on_unload(ErlNifEnv *env, void *priv_data)
{
    (void)env;
    (void)priv_data;
}

static int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info)
{
    (void)env;
    (void)priv_data;
    (void)load_info;
    return 0;
}

ERL_NIF_INIT(instrument_tracer_nif, nif_funcs, &on_load, NULL, NULL, &on_unload)
