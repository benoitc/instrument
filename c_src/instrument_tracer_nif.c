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
#include <stdatomic.h>

/* Session resource - tracks if a tracing session is still active.
 * When parent span ends, it deactivates the session. Spawned children
 * check this on their next trace event and return 'remove' if inactive,
 * causing the VM to stop tracing them.
 */
typedef struct {
    _Atomic int active;  /* 1 = active, 0 = inactive */
} session_resource_t;

static ErlNifResourceType* session_resource_type = NULL;

/* Pool counters - bound the number of events queued per worker.
 * trace/5 increments inflight[idx] before sending to worker idx and drops
 * the event (counting it in `dropped`) once the worker has `max` events
 * outstanding. Workers acknowledge handled events with ack/3.
 */
typedef struct {
    unsigned int n;
    long max;
    _Atomic long dropped;
    _Atomic long inflight[];
} pool_counters_t;

static ErlNifResourceType* pool_counters_type = NULL;

/*
 * enabled/3 - Check if tracing is enabled for the given tracee.
 *
 * TraceTag: atom() - the type of trace event (or trace_status for validation)
 * TracerState: #{pool_size => N, workers => {Name0, ...}, counters => Res, label => Label}
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
 * create_session_resource/0 - Create a new session resource.
 * Returns a resource term that can be included in tracer state.
 * The session starts as active (1).
 */
static ERL_NIF_TERM
create_session_resource(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    session_resource_t* res = enif_alloc_resource(session_resource_type,
                                                   sizeof(session_resource_t));
    if (res == NULL) {
        return enif_make_badarg(env);
    }
    atomic_store(&res->active, 1);  /* Active initially */
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

/*
 * deactivate_session_resource/1 - Mark a session as inactive.
 * Called when the parent span ends. Children will see this on their
 * next trace event and stop being traced.
 */
static ERL_NIF_TERM
deactivate_session_resource(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    session_resource_t* res;
    if (!enif_get_resource(env, argv[0], session_resource_type, (void**)&res)) {
        return enif_make_badarg(env);
    }
    atomic_store(&res->active, 0);  /* Mark inactive */
    return enif_make_atom(env, "ok");
}

/*
 * is_session_active - Helper to check if session is still active.
 * Returns 1 if active (should trace), 0 if inactive (should remove).
 * If no session_ref in tracer_state, returns 1 for backwards compatibility.
 */
static int
is_session_active(ErlNifEnv* env, ERL_NIF_TERM tracer_state)
{
    ERL_NIF_TERM session_ref;
    if (enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "session_ref"), &session_ref)) {
        session_resource_t* res;
        if (enif_get_resource(env, session_ref, session_resource_type, (void**)&res)) {
            return atomic_load(&res->active);
        }
    }
    return 1;  /* No session_ref = legacy behavior, allow tracing */
}

/*
 * enabled_send/3 - Check if send tracing is enabled.
 * Returns 'remove' if session is inactive, triggering cleanup.
 */
static ERL_NIF_TERM
enabled_send(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    if (!is_session_active(env, argv[1])) {
        return enif_make_atom(env, "remove");
    }
    return enif_make_atom(env, "trace");
}

/*
 * enabled_receive/3 - Check if receive tracing is enabled.
 * Returns 'remove' if session is inactive, triggering cleanup.
 */
static ERL_NIF_TERM
enabled_receive(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    if (!is_session_active(env, argv[1])) {
        return enif_make_atom(env, "remove");
    }
    return enif_make_atom(env, "trace");
}

/*
 * enabled_spawn/3 - Check if spawn tracing is enabled.
 * Returns 'remove' if session is inactive, triggering cleanup.
 */
static ERL_NIF_TERM
enabled_spawn(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    if (!is_session_active(env, argv[1])) {
        return enif_make_atom(env, "remove");
    }
    return enif_make_atom(env, "trace");
}

/*
 * enabled_procs/3 - Check if process tracing is enabled.
 * Returns 'remove' if session is inactive, triggering cleanup.
 */
/* The VM raises register/unregister events while holding the name
 * registry lock; resolving a worker by name in trace/5 would take that lock
 * again and hang the node. Those events are never recorded. */
static int
is_registry_event(ErlNifEnv* env, ERL_NIF_TERM tag)
{
    return enif_is_identical(tag, enif_make_atom(env, "register"))
        || enif_is_identical(tag, enif_make_atom(env, "unregister"));
}

static ERL_NIF_TERM
enabled_procs(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    if (is_registry_event(env, argv[0])) {
        return enif_make_atom(env, "discard");
    }
    if (!is_session_active(env, argv[1])) {
        return enif_make_atom(env, "remove");
    }
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
 * payload_size - Approximate size in bytes of `term`, walking at most until
 * the running total passes `budget`. Returns the size when it fits, or a
 * value greater than `budget` (a lower bound) as soon as it does not, so the
 * cost is bounded by the budget rather than by the size of the term.
 * Binaries count their exact byte size.
 *
 * Nesting deeper than PAYLOAD_MAX_DEPTH counts as over budget: recursion
 * depth would otherwise follow the term's nesting (a left-nested iolist is
 * common) and could overflow the scheduler stack. Funs and big integers,
 * whose size is not cheap to know, also count as over budget.
 */
#define PAYLOAD_MAX_DEPTH 64
#define PAYLOAD_MAX_BUDGET (1L << 30)

static long
payload_size(ErlNifEnv* env, ERL_NIF_TERM term, long budget, long acc, int depth)
{
    if (acc > budget) {
        return acc;
    }
    if (depth > PAYLOAD_MAX_DEPTH) {
        return budget + 1;
    }
    ErlNifBinary bin;
    if (enif_is_binary(env, term) && enif_inspect_binary(env, term, &bin)) {
        return acc + 8 + (long)bin.size;
    }
    int arity;
    const ERL_NIF_TERM* elems;
    if (enif_get_tuple(env, term, &arity, &elems)) {
        acc += 8;
        for (int i = 0; i < arity && acc <= budget; i++) {
            acc = payload_size(env, elems[i], budget, acc, depth + 1);
        }
        return acc;
    }
    if (enif_is_list(env, term)) {
        ERL_NIF_TERM head, tail = term;
        while (acc <= budget && enif_get_list_cell(env, tail, &head, &tail)) {
            acc = payload_size(env, head, budget, acc + 8, depth + 1);
        }
        if (acc <= budget && !enif_is_empty_list(env, tail)) {
            acc = payload_size(env, tail, budget, acc, depth + 1);  /* improper tail */
        }
        return acc;
    }
    if (enif_is_map(env, term)) {
        ErlNifMapIterator it;
        ERL_NIF_TERM k, v;
        acc += 8;
        if (enif_map_iterator_create(env, term, &it, ERL_NIF_MAP_ITERATOR_FIRST)) {
            while (acc <= budget && enif_map_iterator_get_pair(env, &it, &k, &v)) {
                acc = payload_size(env, k, budget, acc, depth + 1);
                acc = payload_size(env, v, budget, acc, depth + 1);
                enif_map_iterator_next(env, &it);
            }
            enif_map_iterator_destroy(env, &it);
        }
        return acc;
    }
    if (enif_is_fun(env, term)) {
        return budget + 1;
    }
    ErlNifSInt64 small;
    double dbl;
    if (enif_is_number(env, term)
            && !enif_get_int64(env, term, &small)
            && !enif_get_double(env, term, &dbl)) {
        return budget + 1;  /* big integer */
    }
    /* atoms, small numbers, pids, ports, references */
    return acc + 8;
}

/*
 * trace/5 - Handle a trace event by distributing to worker pool.
 *
 * TraceTag: atom() - send | 'receive' | spawn | exit | etc.
 * TracerState: #{pool_size => N, workers => {Name0, ...}, counters => Res, label => Label}
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

    if (is_registry_event(env, trace_tag)) {
        return enif_make_atom(env, "ok");
    }

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

    /* Resolve the worker by its registered name, so a restarted worker
     * keeps receiving events from processes traced before the restart. */
    int arity;
    const ERL_NIF_TERM* names;
    if (!enif_get_tuple(env, workers_term, &arity, &names)
            || (unsigned int)arity != pool_size) {
        return enif_make_atom(env, "ok");
    }

    ErlNifPid worker_pid;
    if (!enif_whereis_pid(env, names[worker_idx], &worker_pid)) {
        return enif_make_atom(env, "ok");
    }

    /* Admission control: drop once this worker has `max` events queued. */
    pool_counters_t* counters = NULL;
    ERL_NIF_TERM counters_term;
    if (enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "counters"), &counters_term)
            && enif_get_resource(env, counters_term, pool_counters_type,
                                 (void**)&counters)
            && worker_idx < counters->n) {
        /* Reserve first, then check, so concurrent schedulers cannot all
         * pass the check and overshoot the limit. */
        if (atomic_fetch_add(&counters->inflight[worker_idx], 1) >= counters->max) {
            atomic_fetch_sub(&counters->inflight[worker_idx], 1);
            atomic_fetch_add(&counters->dropped, 1);
            return enif_make_atom(env, "ok");
        }
    } else {
        counters = NULL;
    }

    /* Payload limit: replace an oversized payload by {truncated, Size} before
     * it is copied into the worker's mailbox. Size is exact for binaries and
     * a lower bound for large nested terms. */
    ERL_NIF_TERM max_payload_term;
    long max_payload;
    if (enif_get_map_value(env, tracer_state,
            enif_make_atom(env, "max_payload"), &max_payload_term)
            && enif_get_long(env, max_payload_term, &max_payload)
            && max_payload >= 0) {
        if (max_payload > PAYLOAD_MAX_BUDGET) {
            max_payload = PAYLOAD_MAX_BUDGET;
        }
        long size = payload_size(env, trace_term, max_payload, 0, 0);
        if (size > max_payload) {
            trace_term = enif_make_tuple2(env, enif_make_atom(env, "truncated"),
                                          enif_make_long(env, size));
        }
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
    if (!enif_send(env, &worker_pid, msg_env, copied_msg) && counters != NULL) {
        /* Worker died between lookup and send: the event is not queued. */
        atomic_fetch_sub(&counters->inflight[worker_idx], 1);
    }
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
 *
 * Filters internal tracer bootstrap messages that pollute trace output
 * when set_on_spawn propagates tracing to child processes.
 * Pattern: {Ref, {tracer, {instrument_tracer_nif, _}}}
 */
static ERL_NIF_TERM
trace_receive(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM trace_term = argv[3];  /* The received message */

    /* Check if this is an internal tracer bootstrap message */
    /* Pattern: {Ref, {tracer, {instrument_tracer_nif, _}}} */
    int arity;
    const ERL_NIF_TERM* tuple;
    if (enif_get_tuple(env, trace_term, &arity, &tuple) && arity == 2) {
        /* Check second element is {tracer, ...} */
        const ERL_NIF_TERM* inner_tuple;
        int inner_arity;
        if (enif_get_tuple(env, tuple[1], &inner_arity, &inner_tuple) && inner_arity == 2) {
            char atom_str[32];
            if (enif_get_atom(env, inner_tuple[0], atom_str, sizeof(atom_str), ERL_NIF_LATIN1)) {
                if (strcmp(atom_str, "tracer") == 0) {
                    /* This is a tracer control message, discard it */
                    return enif_make_atom(env, "ok");
                }
            }
        }
    }

    /* Normal message, forward to worker */
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

/*
 * new_pool_counters/2 - Create counters for N workers with a per-worker
 * limit of Max queued events.
 */
static ERL_NIF_TERM
new_pool_counters(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned int n;
    long max;
    if (!enif_get_uint(env, argv[0], &n) || n == 0 || n > 65536
            || !enif_get_long(env, argv[1], &max) || max <= 0) {
        return enif_make_badarg(env);
    }
    pool_counters_t* res = enif_alloc_resource(pool_counters_type,
        sizeof(pool_counters_t) + n * sizeof(_Atomic long));
    if (res == NULL) {
        return enif_make_badarg(env);
    }
    res->n = n;
    res->max = max;
    atomic_store(&res->dropped, 0);
    for (unsigned int i = 0; i < n; i++) {
        atomic_store(&res->inflight[i], 0);
    }
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

static int
get_counters_idx(ErlNifEnv* env, const ERL_NIF_TERM argv[],
                 pool_counters_t** res, unsigned int* idx)
{
    return enif_get_resource(env, argv[0], pool_counters_type, (void**)res)
        && enif_get_uint(env, argv[1], idx)
        && *idx < (*res)->n;
}

/*
 * ack/3 - A worker acknowledges N handled events.
 */
static ERL_NIF_TERM
ack(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    pool_counters_t* res;
    unsigned int idx;
    long n;
    if (!get_counters_idx(env, argv, &res, &idx)
            || !enif_get_long(env, argv[2], &n) || n < 0) {
        return enif_make_badarg(env);
    }
    /* Subtract without going below zero (reset_worker/2 may have raced
     * this ack), and without losing a concurrent increment. */
    long cur = atomic_load(&res->inflight[idx]);
    long next;
    do {
        next = cur > n ? cur - n : 0;
    } while (!atomic_compare_exchange_weak(&res->inflight[idx], &cur, next));
    return enif_make_atom(env, "ok");
}

/*
 * reset_worker/2 - Clear a worker's queue count. Called when a worker
 * (re)starts: events queued to a previous incarnation are gone.
 */
static ERL_NIF_TERM
reset_worker(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    pool_counters_t* res;
    unsigned int idx;
    if (!get_counters_idx(env, argv, &res, &idx)) {
        return enif_make_badarg(env);
    }
    atomic_store(&res->inflight[idx], 0);
    return enif_make_atom(env, "ok");
}

/*
 * pool_counters/1 - Returns #{dropped => D, queued => Q, max => M}.
 */
static ERL_NIF_TERM
pool_counters(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    pool_counters_t* res;
    if (!enif_get_resource(env, argv[0], pool_counters_type, (void**)&res)) {
        return enif_make_badarg(env);
    }
    long queued = 0;
    for (unsigned int i = 0; i < res->n; i++) {
        queued += atomic_load(&res->inflight[i]);
    }
    ERL_NIF_TERM keys[3] = {
        enif_make_atom(env, "dropped"),
        enif_make_atom(env, "queued"),
        enif_make_atom(env, "max")
    };
    ERL_NIF_TERM vals[3] = {
        enif_make_long(env, atomic_load(&res->dropped)),
        enif_make_long(env, queued),
        enif_make_long(env, res->max)
    };
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 3, &map);
    return map;
}

static ErlNifFunc nif_funcs[] = {
    /* erl_tracer behavior callbacks - required */
    {"enabled", 3, enabled, 0},
    {"trace", 5, trace, 0},

    /* Session resource management for child process cleanup */
    {"create_session_resource", 0, create_session_resource, 0},
    {"deactivate_session_resource", 1, deactivate_session_resource, 0},

    /* Per-worker queue bound */
    {"new_pool_counters", 2, new_pool_counters, 0},
    {"ack", 3, ack, 0},
    {"reset_worker", 2, reset_worker, 0},
    {"pool_counters", 1, pool_counters, 0},

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
    (void)priv_data;
    (void)load_info;

    /* Create session resource type for tracking active tracing sessions */
    session_resource_type = enif_open_resource_type(env, NULL, "flight_session",
        NULL, ERL_NIF_RT_CREATE, NULL);
    if (session_resource_type == NULL) {
        return -1;
    }

    pool_counters_type = enif_open_resource_type(env, NULL, "flight_pool_counters",
        NULL, ERL_NIF_RT_CREATE, NULL);
    if (pool_counters_type == NULL) {
        return -1;
    }
    return 0;
}

ERL_NIF_INIT(instrument_tracer_nif, nif_funcs, &on_load, NULL, NULL, &on_unload)
