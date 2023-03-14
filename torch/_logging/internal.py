# Top level logging module for torch logging
# Design doc: https://docs.google.com/document/d/1ZRfTWKa8eaPq1AxaiHrq4ASTPouzzlPiuquSBEJYwS8/edit#
# Simple setup for onboarding (see above doc for more detail):
# 1. register_log for all logs you'd like to have control of
# 2. @loggable any classes you'd like to register as artifacts can be toggled as logged/not logged
#    Only requirement here is that it has a __str__ method, and then instances of this class can be passed directly
#    to log.debug(<instance here>)
# 3. call init_logging([.. your log names .. ]) somewhere in your code
# (before the user may attempt to set logs, but after you've executed 1. and 2.)

import collections
import itertools
import logging
import os
import re
from typing import DefaultDict, Dict, Set
from dataclasses import dataclass, field

DEFAULT_LOG_LEVEL = logging.WARN
DEFAULT_FORMATTER = logging.Formatter(
    "[%(asctime)s] %(name)s: [%(levelname)s] %(message)s"
)

@dataclass
class LogRegistry:
    # shorthand name to log qualified name
    name_to_log_qname: Dict[str, str] = field(default_factory=dict)
    # shorthand name to record type
    name_to_rec_type: Dict[str, type] = field(default_factory=dict)
    # log qualified name to set of artifact types
    log_qname_to_rec_types: Dict[str, Set[type]] = field(default_factory=dict)
    # log qualified name to all supported shorthand names
    log_qname_to_loggable_names: Dict[str, Set[str]] = field(default_factory=dict)
    # shorthand names of logs which support verbosity
    log_names_with_verbosity: Set[str] = field(default_factory=set)

    def is_artifact(self, name):
        return name in self.name_to_rec_type

    def is_log(self, name):
        return name in self.name_to_log_qname and name not in self.name_to_rec_type

    def register_log(self, setting_name, log_qname, has_verbosity):
        # Check dupes
        assert log_qname not in self.log_qname_to_rec_types
        assert log_qname not in self.log_qname_to_loggable_names
        assert setting_name not in self.name_to_log_qname

        self.name_to_log_qname[setting_name] = log_qname
        self.log_qname_to_rec_types[log_qname] = set()
        self.log_qname_to_loggable_names[log_qname] = set()

        if has_verbosity:
            self.log_names_with_verbosity.add(setting_name)


    def register_artifact(self, setting_name, artifact_type, log_qname, off_by_default):
        self.log_qname_to_loggable_names[log_qname].add(setting_name)
        self.name_to_log_qname[setting_name] = log_qname
        self.name_to_rec_type[setting_name] = artifact_type
        # if off by default, don't enable it
        # when log_name's log_level is set to DEBUG
        if not off_by_default:
            self.log_qname_to_rec_types[log_qname].add(artifact_type)

    def get_loggable_names(self):
        return list(itertools.chain(self.name_to_log_qname.keys(), self.name_to_rec_type.keys()))

    def get_log_qnames(self):
        return set(self.log_qname_to_rec_types.keys())

    def supports_verbosity(self, log_name):
        return log_name in self.log_names_with_verbosity


log_registry = LogRegistry()

@dataclass
class LogState:
    log_qname_to_level: Dict[str, int] = field(default_factory=dict)
    enabled_artifact_names: Set[str] = field(default_factory=set)
    enabled_settings: Set[str] = field(default_factory=set)

    # reset all logs in log_qname_to_level to default level
    def reset(self):
        pass

    def set_level(self, log_qname, level):
        pass

    def enable_artifact(self, artifact_name):
        pass


log_state = LogState()

# User API for setting log properties
# ex. format set_logs(LOG_NAME=LEVEL, ARTIFACT_NAME=bool)
# ex. set_logs(dynamo=logging.DEBUG, graph_code=True)
def set_logs(**kwargs):
    log_state.reset()

    for key, val in kwargs.items():
        if log_registry.is_artifact(key):
            log_state.enable_artifact(key)
        elif log_registry.is_log(key):
            log_state.set_level(log_registry.name_to_log_qname[key])
            if val not in logging._levelToName:
                raise ValueError(
                    f"Unrecognized log level for log {key}: {val}, valid level values "
                    f"are: {','.join([str(k) for k in logging._levelToName.keys()])}"
                )
        else:
            # Check if it is a qualified name log
            # if so, check that its root logger is parent
            # if so set its level appropriately
            # if not, register it? (maybe)
            raise ValueError(
                f"Unrecognized log or artifact name passed to set_logs: {key}"
            )


def loggable(setting_name, log_name, off_by_default=False):
    """
    Enables a type to be controlled by the env var and user API with the setting_name
    Args:
        setting_name: the shorthand name used in the env var and user API
        log_name: the log name that the setting_name is associated with
        off_by_default: whether setting the associated log_name's level to DEBUG will
            print the the artifact
    """
    def register(cls):
        log_registry.register_artifact(setting_name, cls, log_name, off_by_default)

        return cls

    return register


def register_log(setting_name, log_name, has_verbosity=True):
    """
    Enables a log to be controlled by the env var and user API with the setting_name
    Args:
        setting_name:  the shorthand name used in the env var and user API
        log_name:  the log name that the setting_name is associated with
        has_verbosity: whether the log supports different verbosity levels
    """
    log_registry.register_log(setting_name, log_name, has_verbosity)


INCR_VERBOSITY_CHAR = "+"
DECR_VERBOSITY_CHAR = "-"
VERBOSITY_REGEX = (
    "("
    + "|".join([re.escape(INCR_VERBOSITY_CHAR), re.escape(DECR_VERBOSITY_CHAR)])
    + "?)"
)

# match a comma separated list of loggable names (whitespace allowed after commas)
def gen_settings_regex(loggable_names):
    loggable_names_verbosity = [
        (VERBOSITY_REGEX if log_registry.supports_verbosity(name) else "") + name
        for name in loggable_names
    ]
    group = "(" + "|".join(loggable_names_verbosity) + ")"
    return re.compile(f"({group},\\s*)*{group}?")


def _validate_settings(settings):
    return re.fullmatch(gen_settings_regex(log_registry.get_loggable_names()), settings) is not None


def _parse_log_settings(settings):
    if settings == "":
        return dict()

    if not _validate_settings(settings):
        raise ValueError(
            f"Invalid log settings: {settings}, must be a comma separated list of registerered log or artifact names."
        )

    settings = re.sub(r"\s+", "", settings)
    log_names = settings.split(",")

    def get_name_level_pair(name):
        clean_name = name.replace(INCR_VERBOSITY_CHAR, "")
        clean_name = clean_name.replace(DECR_VERBOSITY_CHAR, "")
        level = None
        if log_registry.is_log(clean_name):
            if name[0] == INCR_VERBOSITY_CHAR:
                level = logging.DEBUG
            elif name[0] == DECR_VERBOSITY_CHAR:
                level = logging.ERROR
            else:
                level = logging.INFO

        return clean_name, level

    name_levels = [get_name_level_pair(name) for name in log_names]
    return {name: level for name, level in name_levels}


class FilterByType(logging.Filter):
    def __init__(self, enabled_types):
        self.set_enabled_types(enabled_types)

    def filter(self, record):
        return isinstance(record.msg, self.enabled_types)

    def set_enabled_types(self, enabled_types):
        self.enabled_types = tuple(set(enabled_types))


def _get_log_settings():
    log_setting = os.environ.get("TORCH_LOGS", None)
    if log_setting is None:
        return {}
    else:
        return _parse_log_settings(log_setting)


# setup custom handlers
# if the log level of a component is set to INFO, setup
# an additional handler to print those messages, because
# the debug handler is what handles custom objects like guards,
# bytecode, etc.
# if the log level of a component is set to DEBUG, allow all
# string messages and allowed types (other than those off by default)
def _setup_handlers(create_handler_fn, log, enabled_types, level=None):
    debug_handler = create_handler_fn()
    debug_handler.setFormatter(DEFAULT_FORMATTER)
    debug_handler.setLevel(logging.DEBUG)

    if level == logging.DEBUG:
        enabled_types = enabled_types.union({str})

    filter = FilterByType(enabled_types)
    debug_handler.addFilter(filter)
    log.addHandler(debug_handler)

    if level is not None and level > logging.DEBUG:
        generic_handler = create_handler_fn()
        generic_handler.setFormatter(DEFAULT_FORMATTER)
        generic_handler.setLevel(level)
        log.addHandler(generic_handler)


# mark handlers that we've created
# so we don't modify user handlers
def _tag_handler(handler):
    handler.__torch_log_handler = True
    return handler


def _is_torch_handler(handler):
    return hasattr(handler, "__torch_log_handler")


# clears all torch handlers on specified loggers
def _clear_handlers(log):
    to_remove = [handler for handler in log.handlers if _is_torch_handler(handler)]
    for handler in to_remove:
        log.removeHandler(handler)


# initialize loggers log_names
# each developer component should call this for their own logs
# in the appropriate location after relevant types have been registered
def init_logs(log_file_name=None):
    for log_name in log_registry.get_log_qnames():
        log = logging.getLogger(log_name)
        log.setLevel(logging.DEBUG)  # allow all messages through to the handlers
        log.propagate = False
        _clear_handlers(log)

    name_to_levels = _get_log_settings()
    log_qname_to_enabled_types: DefaultDict[str, Set[type]] = collections.defaultdict(set)
    log_qname_to_level = dict()

    # generate a map of log_name -> the types that should be logged
    for name, level in name_to_levels.items():
        log_qname = log_registry.name_to_log_qname[name]
        if log_registry.is_log(name):
            log_qname_to_level[log_qname] = level
            logging.getLogger(log_qname).setLevel(
                logging.DEBUG
            )  # allow all messages through logger
            # ensure log_name is in the dictionary
            rec_types = log_qname_to_enabled_types[log_qname]
            if level == logging.DEBUG or log_registry.supports_verbosity(name):
                rec_types.update(log_registry.log_qname_to_rec_types[log_qname])
        else:
            log_qname_to_enabled_types[log_qname].add(log_registry.name_to_rec_type[name])

    for log_name, enabled_types in log_qname_to_enabled_types.items():
        log = logging.getLogger(log_name)
        level = log_qname_to_level.get(log_name, DEFAULT_LOG_LEVEL)

        _setup_handlers(
            lambda: _tag_handler(logging.StreamHandler()),
            log,
            enabled_types,
            level,
        )

        if log_file_name is not None:
            _setup_handlers(
                lambda: _tag_handler(logging.FileHandler(log_file_name)),
                log,
                enabled_types,
                level,
            )
