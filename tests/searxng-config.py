"""Exercise the packaged /config handler without starting search workers."""
import ast
from pathlib import Path
from types import ModuleType, SimpleNamespace
import unittest

from flask import Flask, jsonify
import searx
from searx import get_setting, settings
from searx.engines import update_engine_attributes
from searx.locales import LOCALE_NAMES
from searx.version import GIT_BRANCH, GIT_URL, VERSION_STRING


class Preferences:
    def validate_token(self, engine):
        return engine.name != "restricted fixture"


def make_engine(name, module_type, configured_type):
    engine = ModuleType("fixture")
    if module_type is not None:
        engine.engine_type = module_type
    configuration = {
        "name": name,
        "shortcut": "fixture",
        "categories": ["general"],
        "paging": True,
        "language_support": True,
        "safesearch": True,
        "time_range_support": True,
        "timeout": 1.25,
    }
    if configured_type is not None:
        configuration["engine_type"] = configured_type
    update_engine_attributes(engine, configuration)
    engine.traits = SimpleNamespace(languages={"en": "en"}, regions={"en-US": "us"})
    return engine


def config_response(engines):
    # Importing webapp invokes init(), including external-engine initialization.
    # Compile only the installed handler; exercise its real Flask JSON response.
    source = Path(searx.__file__).parent / "webapp.py"
    handlers = [node for node in ast.parse(source.read_text()).body
                if isinstance(node, ast.FunctionDef) and node.name == "config"]
    assert len(handlers) == 1
    handler = handlers[0]
    handler.decorator_list = []
    namespace = {
        "jsonify": jsonify,
        "engines": {engine.name: engine for engine in engines},
        "categories": {"general": []},
        "sxng_request": SimpleNamespace(preferences=Preferences()),
        "settings": settings,
        "get_setting": get_setting,
        "searx": SimpleNamespace(plugins=SimpleNamespace(STORAGE=[])),
        "limiter": SimpleNamespace(get_cfg=lambda: {}, is_installed=lambda: False),
        "LOCALE_NAMES": LOCALE_NAMES,
        "VERSION_STRING": VERSION_STRING,
        "GIT_URL": GIT_URL,
        "GIT_BRANCH": GIT_BRANCH,
    }
    exec(compile(ast.Module(body=[handler], type_ignores=[]), str(source), "exec"), namespace)
    app = Flask(__name__)
    app.testing = True
    app.add_url_rule("/config", endpoint="config", view_func=namespace["config"])
    return app.test_client().get("/config")


class ConfigEndpoint(unittest.TestCase):
    def test_effective_types_include_defaults_and_settings_overrides(self):
        cases = (
            (None, None, "online"),
            ("online_dictionary", None, "online_dictionary"),
            ("online_currency", None, "online_currency"),
            ("online_dictionary", "online_currency", "online_currency"),
        )
        for module_type, configured_type, expected in cases:
            with self.subTest(module_type=module_type, configured_type=configured_type):
                response = config_response([make_engine("fixture", module_type, configured_type)])
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.get_json()["engines"][0].get("engine_type"), expected)

    def test_existing_metadata_and_token_filter_are_preserved(self):
        response = config_response([
            make_engine("visible fixture", None, None),
            make_engine("restricted fixture", "online_dictionary", None),
        ])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["engines"], [{
            "name": "visible fixture",
            "engine_type": "online",
            "categories": ["general"],
            "shortcut": "fixture",
            "enabled": True,
            "paging": True,
            "language_support": True,
            "languages": ["en"],
            "regions": ["en-US"],
            "safesearch": True,
            "time_range_support": True,
            "timeout": 1.25,
        }])


if __name__ == "__main__":
    unittest.main()
