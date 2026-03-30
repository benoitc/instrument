%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_lib).
-author("benoitc").

%% API
-export([
  mk_info/2,
  table/0,
  table/1,
  tables/0
]).

-include("instrument.hrl").

mk_info(Name, Help) ->
  #metric_info{name=Name, help=Help}.


tables() ->
  [table(S) || S <- lists:seq(1,erlang:system_info(schedulers))].

table() ->
  table(erlang:system_info(scheduler_id)).

table(1) -> instrument_registry_1;
table(2) -> instrument_registry_2;
table(3) -> instrument_registry_3;
table(4) -> instrument_registry_4;
table(5) -> instrument_registry_5;
table(6) -> instrument_registry_6;
table(7) -> instrument_registry_7;
table(8) -> instrument_registry_8;
table(9) -> instrument_registry_9;
table(10) -> instrument_registry_10;
table(11) -> instrument_registry_11;
table(12) -> instrument_registry_12;
table(13) -> instrument_registry_13;
table(14) -> instrument_registry_14;
table(15) -> instrument_registry_15;
table(16) -> instrument_registry_16;
table(17) -> instrument_registry_17;
table(18) -> instrument_registry_18;
table(19) -> instrument_registry_19;
table(20) -> instrument_registry_20;
table(21) -> instrument_registry_21;
table(22) -> instrument_registry_22;
table(23) -> instrument_registry_23;
table(24) -> instrument_registry_24;
table(25) -> instrument_registry_25;
table(26) -> instrument_registry_26;
table(27) -> instrument_registry_27;
table(28) -> instrument_registry_28;
table(29) -> instrument_registry_29;
table(30) -> instrument_registry_30;
table(31) -> instrument_registry_31;
table(32) -> instrument_registry_32;
table(33) -> instrument_registry_33;
table(34) -> instrument_registry_34;
table(35) -> instrument_registry_35;
table(36) -> instrument_registry_36;
table(37) -> instrument_registry_37;
table(38) -> instrument_registry_38;
table(39) -> instrument_registry_39;
table(40) -> instrument_registry_40;
table(41) -> instrument_registry_41;
table(42) -> instrument_registry_42;
table(43) -> instrument_registry_43;
table(44) -> instrument_registry_44;
table(45) -> instrument_registry_45;
table(46) -> instrument_registry_46;
table(47) -> instrument_registry_47;
table(48) -> instrument_registry_48;
table(49) -> instrument_registry_49;
table(50) -> instrument_registry_50;
table(51) -> instrument_registry_51;
table(52) -> instrument_registry_52;
table(53) -> instrument_registry_53;
table(54) -> instrument_registry_54;
table(55) -> instrument_registry_55;
table(56) -> instrument_registry_56;
table(57) -> instrument_registry_57;
table(58) -> instrument_registry_58;
table(59) -> instrument_registry_59;
table(60) -> instrument_registry_60;
table(61) -> instrument_registry_61;
table(62) -> instrument_registry_62;
table(63) -> instrument_registry_63;
table(64) -> instrument_registry_64;
table(N) when is_integer(N), N > 20 ->
  list_to_atom("instrument_registry_" ++ integer_to_list(N)).