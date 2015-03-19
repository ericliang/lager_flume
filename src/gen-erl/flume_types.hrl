-ifndef(_flume_types_included).
-define(_flume_types_included, yeah).

-define(FLUME_STATUS_OK, 0).
-define(FLUME_STATUS_FAILED, 1).
-define(FLUME_STATUS_ERROR, 2).
-define(FLUME_STATUS_UNKNOWN, 3).

%% struct 'ThriftFlumeEvent'

-record('ThriftFlumeEvent', {'headers' = dict:new() :: dict(),
                             'body' :: string() | binary()}).
-type 'ThriftFlumeEvent'() :: #'ThriftFlumeEvent'{}.

-endif.
