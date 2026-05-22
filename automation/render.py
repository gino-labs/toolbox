import yaml
import argparse
from pathlib import Path
from jinja2 import Environment, FileSystemLoader

def render_template(j2_file: str, vars_file: str):
    template_dir = Path("../templates")
    out_file = Path(f"../.vault/{j2_file.rstrip(".j2")}")
    vars_file = Path(vars_file)

    with vars_file.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    env = Environment(loader=FileSystemLoader(template_dir), trim_blocks=True, keep_trailing_newline=True)
    template = env.get_template(j2_file)
    rendered = template.render(**data)
    out_file.write_text(rendered, encoding="utf-8")

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jinja-file", required=True, help="Jinja2 file to render.")
    parser.add_argument("--vars-file", required=True, help="Yaml file containing vars for rendering data.")
    return parser

if __name__ == "__main__":
    p = build_parser()
    args = p.parse_args()

    render_template(args.jinja_file, args.vars_file)
