#!/usr/bin/env python3

"""
Chartify - Convert Kubernetes manifests to Helm chart with conditionals
"""

import sys
import logging
from pathlib import Path
from typing import Dict, Any, List

try:
    import click
    import yaml
except ImportError as e:
    print(f"Missing required dependency: {e}")
    print("Install with: pip install click PyYAML")
    sys.exit(1)


def log_debug_manifest(label: str, manifest_path: str, manifests: List[Dict[str, Any]]) -> None:
    """Log manifest information for debugging"""
    logging.info(f"   Loaded {len(manifests)} resources from {label}: {manifest_path}")
    logging.info(f"   {label.capitalize()} resources:")
    for i, manifest in enumerate(manifests, 1):
        kind = manifest.get('kind', 'Unknown')
        name = manifest.get('metadata', {}).get('name', 'Unnamed')
        logging.info(f"     {i}. {kind}/{name}")


def setup_logging(debug: bool) -> None:
    """Configure logging based on debug level"""
    logging.getLogger().handlers.clear()

    level = logging.WARNING
    if debug:
        level = logging.INFO

    handler = logging.StreamHandler()
    handler.emit = lambda record: click.echo(handler.format(record), err=True)
    handler.setFormatter(logging.Formatter("%(message)s"))

    logger = logging.getLogger()
    logger.setLevel(level)
    logger.addHandler(handler)


def load_manifests(path: str) -> List[Dict[str, Any]]:
    """Load YAML manifests from file or directory"""
    path_obj = Path(path)
    manifests = []

    if path_obj.is_file():
        # Load single file
        with open(path_obj, 'r') as f:
            try:
                docs = list(yaml.safe_load_all(f))
                manifests.extend([doc for doc in docs if doc])
            except yaml.YAMLError as e:
                raise click.ClickException(f"Error parsing YAML file {path}: {e}")
    elif path_obj.is_dir():
        # Load all YAML files from directory
        yaml_files = list(path_obj.glob('**/*.yaml')) + list(path_obj.glob('**/*.yml'))

        if not yaml_files:
            raise click.ClickException(f"No YAML files found in directory: {path}")

        for yaml_file in yaml_files:
            with open(yaml_file, 'r') as f:
                try:
                    docs = list(yaml.safe_load_all(f))
                    manifests.extend([doc for doc in docs if doc])
                except yaml.YAMLError as e:
                    raise click.ClickException(f"Error parsing YAML file {yaml_file}: {e}")
    else:
        raise click.ClickException(f"Path not found: {path}")

    if not manifests:
        raise click.ClickException(f"No valid manifests found in: {path}")

    return manifests


def get_resource_key(resource: Dict[str, Any]) -> str:
    """Create a resource key that ensures uniqueness (includes namespace when present)"""
    api_version = resource.get('apiVersion', 'v1')
    kind = resource.get('kind', 'unknown')
    metadata = resource.get('metadata', {})
    name = metadata.get('name', 'unnamed')
    namespace = metadata.get('namespace')

    # Parse apiVersion to extract group and version
    if '/' in api_version:
        group, version = api_version.split('/', 1)
    else:
        # Core resources have no group (e.g., 'v1' -> group='', version='v1')
        group, version = '', api_version

    # Format key components for uniqueness
    group_part = group if group else 'core'
    kind_lower = kind.lower()

    # Include namespace for namespaced resources (for uniqueness)
    if namespace:
        return f"{group_part}_{version}_{kind_lower}_{namespace}_{name}"
    else:
        return f"{group_part}_{version}_{kind_lower}_{name}"


def get_template_filename(resource: Dict[str, Any]) -> str:
    """Generate template filename by using resource key + .yaml extension"""
    return f"{get_resource_key(resource)}.yaml"


def get_resource_diffs(base_resources: List[Dict[str, Any]], overlay_resources: List[Dict[str, Any]]) -> Dict[str, tuple]:
    """Get resource-level diffs"""
    # Group resources by key - this is needed for template file naming
    resources1 = {get_resource_key(r): r for r in base_resources}
    resources2 = {get_resource_key(r): r for r in overlay_resources}
    results = {}

    # Added: only in overlay
    for key, resource in resources2.items():
        if key not in resources1:
            results[key] = ('added', None, resource)

    # Removed: only in base
    for key, resource in resources1.items():
        if key not in resources2:
            results[key] = ('removed', resource, None)

    # Compare existing resources
    for key in resources1.keys() & resources2.keys():
        r1, r2 = resources1[key], resources2[key]
        if r1 != r2:
            results[key] = ('modified', r1, r2)
        else:
            results[key] = ('unchanged', r1, r2)

    return results


def is_crd(resource: Dict[str, Any]) -> bool:
    """Check if a resource is a Custom Resource Definition"""
    return (resource.get('kind') == 'CustomResourceDefinition' and 
            resource.get('apiVersion', '').startswith('apiextensions.k8s.io/'))


def generate_helm_template(resource_diff: tuple, condition: str) -> tuple[str, str, str]:
    """Generate Helm template folder, filename and content for any resource type

    Args:
        resource_diff: Tuple from resource_diffs (diff_type, base_res, overlay_res)
        condition: Condition key for templating

    Returns:
        Tuple of (folder, filename, template_content)
    """
    diff_type, base_res, overlay_res = resource_diff

    # Determine which resource to use for filename generation and key extraction
    if diff_type == 'added':
        filename_resource = overlay_res
        key_resource = overlay_res
    elif diff_type == 'removed':
        filename_resource = base_res
        key_resource = base_res
    elif diff_type in ['unchanged', 'modified']:
        filename_resource = base_res
        key_resource = base_res

    filename = get_template_filename(filename_resource)
    key = get_resource_key(key_resource)

    folder = "crds" if is_crd(filename_resource) else "templates"

    lines = []
    lines.append(f"# Resource: {key}")
    lines.append("---")

    logging.info(f"Generating template for {key} with diff_type {diff_type}")

    if diff_type == "added":
        lines.append(f"{{{{- if .Values.{condition} }}}}")
        lines.append(yaml.dump(overlay_res, default_flow_style=False).rstrip())
        lines.append("{{- end }}")
    elif diff_type == "removed":
        lines.append(f"{{{{- if not .Values.{condition} }}}}")
        lines.append(yaml.dump(base_res, default_flow_style=False).rstrip())
        lines.append("{{- end }}")
    elif diff_type == "unchanged":
        lines.append(yaml.dump(base_res, default_flow_style=False).rstrip())
    elif diff_type == "modified":
        lines.append(f"{{{{- if .Values.{condition} }}}}")
        lines.append(yaml.dump(overlay_res, default_flow_style=False).rstrip())
        lines.append("{{- else }}")
        lines.append(yaml.dump(base_res, default_flow_style=False).rstrip())
        lines.append("{{- end }}")

    template_content = "\n".join(lines)
    return folder, filename, template_content


def set_nested_value(dictionary: Dict[str, Any], key_path: str, value: Any) -> None:
    """Set a nested dictionary value using dot notation key path"""
    keys = key_path.split('.')
    current = dictionary

    # Navigate/create the nested structure
    for key in keys[:-1]:
        if key not in current:
            current[key] = {}
        elif not isinstance(current[key], dict):
            # If existing value is not a dict, we need to replace it
            current[key] = {}
        current = current[key]

    current[keys[-1]] = value


def load_values_file(values_file: str) -> Dict[str, Any]:
    """
    Load and parse a YAML values file.
    
    Args:
        values_file: Path to the values file to load, or None
        
    Returns:
        Dict containing the loaded values, or None if no file provided
        
    Raises:
        click.ClickException: If there's an error reading or parsing the file
    """
    if not values_file:
        return None
        
    logging.info(f"Loading base values from: {values_file}")
    try:
        with open(values_file, 'r') as f:
            base_values = yaml.safe_load(f) or {}
        logging.info(f"Base values loaded with {len(base_values)} top-level keys")
        return base_values
    except yaml.YAMLError as e:
        raise click.ClickException(f"Error parsing values file {values_file}: {e}")
    except Exception as e:
        raise click.ClickException(f"Error reading values file {values_file}: {e}")


def create_chart_structure(output_path: str, chart_name: str, condition_key: str,
                          default_condition: bool, chart_version: str = '0.1.0',
                          chart_app_version: str = '1.0.0', base_values: Dict[str, Any] = None) -> None:
    """Create Helm chart directory structure and base files"""
    chart_path = Path(output_path)
    chart_path.mkdir(parents=True, exist_ok=True)
    (chart_path / "templates").mkdir(exist_ok=True)
    (chart_path / "crds").mkdir(exist_ok=True)

    chart_yaml = {
        'apiVersion': 'v2',
        'name': chart_name,
        'description': f'Helm chart for {chart_name}',
        'type': 'application',
        'version': chart_version,
        'appVersion': chart_app_version
    }

    with open(chart_path / "Chart.yaml", 'w') as f:
        yaml.dump(chart_yaml, f, default_flow_style=False)

    if base_values:
        values = base_values.copy()
    else:
        values = {}

    # Set the condition key with proper nested structure
    set_nested_value(values, condition_key, default_condition)

    with open(chart_path / "values.yaml", 'w') as f:
        yaml.dump(values, f, default_flow_style=False)


def write_template_file(output_path: str, folder: str, filename: str, content: str) -> None:
    """Write a template file to the specified folder (templates or crds)"""
    template_path = Path(output_path) / folder / filename
    with open(template_path, 'w') as f:
        f.write(content)


@click.command()
@click.argument('base_filename', type=click.Path(exists=True))
@click.argument('overlay_filename', type=click.Path(exists=True))
@click.option('--condition', required=True, 
              help='Condition key for templating (creates .Values.KEY in templates)')
@click.option('--output', default='./chart', 
              help='Output chart directory (default: ./chart)')
@click.option('--chart-name', 
              help='Chart name (default: derived from output directory)')
@click.option('--default-condition', is_flag=True, default=True,
              help='Set condition default to true (default: true)')
@click.option('--config', type=click.Path(exists=True),
              help='Use configuration file')
@click.option('--debug', is_flag=True,
              help='Show detailed processing information')
@click.option('--chart-version', default='0.1.0',
              help='Chart version to set in Chart.yaml (default: 0.1.0)')
@click.option('--chart-app-version', default='1.0.0',
              help='Chart appVersion to set in Chart.yaml (default: 1.0.0)')
@click.option('--values-file', type=click.Path(exists=True),
              help='Base values.yaml file to extend (condition will be added to it)')
def main(base_filename, overlay_filename, condition, output, chart_name, default_condition, 
         config, debug, chart_version, chart_app_version, values_file):
    """
    Convert two sets of Kubernetes manifests into a Helm chart with conditionals.

    BASE_FILENAME: First manifest file or directory (base)
    OVERLAY_FILENAME: Second manifest file or directory (overlay)

    Examples:

      # Basic usage
      ./chartify base.yaml overlay.yaml --condition enableFeature

      # With custom output and chart name
      ./chartify manifests/base manifests/overlay \\
        --condition production \\
        --output ./my-chart \\
        --chart-name my-app

      # With debug information
      ./chartify base.yaml overlay.yaml \\
        --condition enableFeature \\
        --debug
    """

    setup_logging(debug)

    # Determine chart name if not provided
    if not chart_name:
        chart_name = Path(output).name
        if chart_name in ['.', '']:
            chart_name = 'generated-chart'

    logging.info(f"Configuration: {{'base': '{base_filename}', 'overlay': '{overlay_filename}', 'condition': '{condition}', 'output': '{output}', 'chart_name': '{chart_name}', 'default_condition': {default_condition}, 'chart_version': '{chart_version}', 'chart_app_version': '{chart_app_version}'}}")
    if values_file:
        logging.info(f"   Base values file: {values_file}")
    if config:
        logging.info(f"   Configuration file: {config}")
    logging.info("")

    try:
        base_path = Path(base_filename)
        overlay_path = Path(overlay_filename)

        if not base_path.exists():
            raise click.ClickException(f"Base path does not exist: {base_filename}")

        if not overlay_path.exists():
            raise click.ClickException(f"Overlay path does not exist: {overlay_filename}")

        logging.info(f"Arguments validated successfully!")
        logging.info(f"   Chart '{chart_name}' will be generated from:")
        logging.info(f"   Base: {base_filename}")
        logging.info(f"   Overlay: {overlay_filename}")
        logging.info(f"   Condition: .Values.{condition}")

        logging.info("Loading manifests...")

        base_resources = load_manifests(base_filename)
        overlay_resources = load_manifests(overlay_filename)

        log_debug_manifest("base", base_filename, base_resources)
        log_debug_manifest("overlay", overlay_filename, overlay_resources)
        logging.info("Manifests loaded successfully!")

        
        logging.info("Analyzing differences...")
        resource_diffs = get_resource_diffs(base_resources, overlay_resources)

        logging.info("Generating Helm chart...")

        base_values = load_values_file(values_file)

        create_chart_structure(output, chart_name, condition, default_condition, chart_version, chart_app_version, base_values)

        for resource_key, resource_diff in resource_diffs.items():
            folder, filename, template_content = generate_helm_template(resource_diff, condition)
            write_template_file(output, folder, filename, template_content)

        click.echo(f"Helm chart generated successfully!")
        click.echo(f"Chart: {chart_name}")
        click.echo(f"Output: {output}")
        click.echo(f"Condition: .Values.{condition} (default: {default_condition})")

    except Exception as e:
        logging.error(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()