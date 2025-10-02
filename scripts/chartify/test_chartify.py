#!/usr/bin/env python3

"""
Test suite for chartify.py - Kubernetes manifests to Helm chart conversion
"""

import os
import sys
import tempfile
import yaml
import pytest
from pathlib import Path
from typing import Dict, Any, List

# Add the scripts directory to the path to import chartify
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chartify


@pytest.fixture
def assets_dir():
    """Fixture providing path to test assets directory"""
    return Path(__file__).parent / "assets"


@pytest.fixture
def temp_chart_dir():
    """Fixture providing a temporary directory for chart generation"""
    with tempfile.TemporaryDirectory() as temp_dir:
        yield Path(temp_dir)


def test_annotation_difference_overlay(assets_dir, temp_chart_dir):
    """
    Test overlaying two manifests with only annotation differences in one resource.

    This test demonstrates the core functionality where:
    - Base and overlay have multiple resources (Deployment, Service, ConfigMap)
    - Only the Service resource has different annotations between base and overlay
    - Expected result: Service gets conditional template, others remain unchanged
    """
    # Get paths to test assets
    base_file = assets_dir / "base-annotation-test.yaml"
    overlay_file = assets_dir / "overlay-annotation-test.yaml"

    # Verify test assets exist
    assert base_file.exists(), f"Base test asset not found: {base_file}"
    assert overlay_file.exists(), f"Overlay test asset not found: {overlay_file}"

    output_path = temp_chart_dir / "test-chart"

    # Load manifests to verify test setup
    base_resources = chartify.load_manifests(str(base_file))
    overlay_resources = chartify.load_manifests(str(overlay_file))

    # Verify we have the expected resources
    assert len(base_resources) == 3, f"Expected 3 base resources, got {len(base_resources)}"
    assert len(overlay_resources) == 3, f"Expected 3 overlay resources, got {len(overlay_resources)}"

    # Get resource differences
    resource_diffs = chartify.get_resource_diffs(base_resources, overlay_resources)

    # Analyze the differences - should have exactly one modified resource (Service)
    diff_types = [diff_type for diff_type, _, _ in resource_diffs.values()]
    modified_count = diff_types.count('modified')
    unchanged_count = diff_types.count('unchanged')

    assert modified_count == 1, f"Expected exactly 1 modified resource, got {modified_count}"
    assert unchanged_count == 2, f"Expected exactly 2 unchanged resources, got {unchanged_count}"

    # Find the modified resource - should be the Service
    modified_resource = None
    for key, (diff_type, base_res, overlay_res) in resource_diffs.items():
        if diff_type == 'modified':
            modified_resource = (key, base_res, overlay_res)
            assert base_res['kind'] == 'Service', f"Modified resource should be Service, got {base_res['kind']}"
            assert base_res['metadata']['name'] == 'web-app-service', f"Modified resource should be web-app-service"

            # Verify the difference is in annotations
            base_annotations = base_res['metadata'].get('annotations', {})
            overlay_annotations = overlay_res['metadata'].get('annotations', {})

            # Should have different number of annotations
            assert len(base_annotations) != len(overlay_annotations), "Annotations should be different"
            break

    assert modified_resource is not None, "Should have found exactly one modified resource"

    # Generate the Helm chart
    condition_key = "global.enablePrometheus"
    chartify.create_chart_structure(
        str(output_path),
        "test-chart",
        condition_key,
        True,  # default condition
        "1.0.0",  # chart version
        "1.0.0"   # app version
    )

    # Generate templates
    template_count = 0
    service_template_content = None

    for resource_key, resource_diff in resource_diffs.items():
        folder, filename, template_content = chartify.generate_helm_template(resource_diff, condition_key)
        chartify.write_template_file(str(output_path), folder, filename, template_content)
        template_count += 1

        # Check if this is the Service template (modified resource)
        diff_type, base_res, overlay_res = resource_diff
        if diff_type == 'modified' and base_res['kind'] == 'Service':
            service_template_content = template_content

    # Verify the Service template has conditional blocks
    assert service_template_content is not None, "Service template should have been generated"
    assert f"{{{{- if .Values.{condition_key} }}}}" in service_template_content, "Template should have if condition"
    assert "{{- else }}" in service_template_content, "Template should have else block"
    assert "{{- end }}" in service_template_content, "Template should have end block"

    # Verify chart structure
    chart_yaml_path = output_path / "Chart.yaml"
    values_yaml_path = output_path / "values.yaml"
    templates_dir = output_path / "templates"

    assert chart_yaml_path.exists(), "Chart.yaml should exist"
    assert values_yaml_path.exists(), "values.yaml should exist"
    assert templates_dir.exists(), "templates directory should exist"

    # Verify Chart.yaml content
    with open(chart_yaml_path) as f:
        chart_data = yaml.safe_load(f)
        assert chart_data['name'] == 'test-chart'
        assert chart_data['version'] == '1.0.0'

    # Verify values.yaml has the correct nested structure
    with open(values_yaml_path) as f:
        values_data = yaml.safe_load(f)

        # Check nested structure for global.enablePrometheus
        assert 'global' in values_data
        assert 'enablePrometheus' in values_data['global']
        assert values_data['global']['enablePrometheus'] is True

    # Verify template files were created
    template_files = list(templates_dir.glob("*.yaml"))
    assert len(template_files) == template_count


def test_nested_condition_key(temp_chart_dir):
    """
    Test that deeply nested condition keys work correctly in values.yaml
    """
    output_path = temp_chart_dir / "nested-test-chart"

    # Test deeply nested condition key
    condition_key = "global.features.monitoring.enablePrometheus"
    chartify.create_chart_structure(
        str(output_path),
        "nested-test-chart",
        condition_key,
        False,  # default condition
        "2.0.0",
        "2.0.0"
    )

    # Verify values.yaml structure
    values_yaml_path = output_path / "values.yaml"
    with open(values_yaml_path) as f:
        values_data = yaml.safe_load(f)

        # Check deeply nested structure
        assert 'global' in values_data
        assert 'features' in values_data['global']
        assert 'monitoring' in values_data['global']['features']
        assert 'enablePrometheus' in values_data['global']['features']['monitoring']
        assert values_data['global']['features']['monitoring']['enablePrometheus'] is False


@pytest.mark.parametrize("condition_key,expected_structure", [
    ("simple", {"simple": True}),
    ("global.setting", {"global": {"setting": True}}),
    ("global.features.auth.enabled", {"global": {"features": {"auth": {"enabled": True}}}}),
    ("app.config.database.ssl", {"app": {"config": {"database": {"ssl": True}}}}),
])
def test_nested_value_creation(temp_chart_dir, condition_key, expected_structure):
    """
    Test that set_nested_value creates correct nested structures for various condition keys
    """
    values = {}
    chartify.set_nested_value(values, condition_key, True)
    assert values == expected_structure


def test_resource_key_generation():
    """
    Test that resource keys are generated correctly for uniqueness
    """
    # Test core resource (no group)
    core_resource = {
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {'name': 'my-service', 'namespace': 'default'}
    }
    key = chartify.get_resource_key(core_resource)
    assert key == 'core_v1_service_default_my-service'

    # Test custom resource with group
    custom_resource = {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': 'my-app'}
    }
    key = chartify.get_resource_key(custom_resource)
    assert key == 'apps_v1_deployment_my-app'

    # Test cluster-scoped resource (no namespace)
    cluster_resource = {
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'ClusterRole',
        'metadata': {'name': 'admin'}
    }
    key = chartify.get_resource_key(cluster_resource)
    assert key == 'rbac.authorization.k8s.io_v1_clusterrole_admin'


def test_template_filename_generation():
    """
    Test that template filenames are generated in the correct Kubernetes format
    """
    # Test service with namespace
    service = {
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {'name': 'web-service', 'namespace': 'default'}
    }
    filename = chartify.get_template_filename(service)
    assert filename == 'core_v1_service_default_web-service.yaml'

    # Test deployment without namespace
    deployment = {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': 'my-app'}
    }
    filename = chartify.get_template_filename(deployment)
    assert filename == 'apps_v1_deployment_my-app.yaml'


def test_added_and_removed_resources(assets_dir, temp_chart_dir):
    """
    Test handling of resources that are added in overlay or removed from base.

    This test verifies:
    - Base has 3 resources: Deployment, Service, ConfigMap
    - Overlay has 6 resources: same 3 + Redis Deployment, Redis Service, Migration Job
    - Added resources get {{- if .Values.condition }} wrapper
    - Removed resources get {{- if not .Values.condition }} wrapper
    - Modified resources get {{- if .Values.condition }} ... {{- else }} ... {{- end }}
    """
    # Get paths to test assets
    base_file = assets_dir / "base-missing-resources.yaml"
    overlay_file = assets_dir / "overlay-missing-resources.yaml"

    # Verify test assets exist
    assert base_file.exists(), f"Base test asset not found: {base_file}"
    assert overlay_file.exists(), f"Overlay test asset not found: {overlay_file}"

    output_path = temp_chart_dir / "missing-resources-chart"

    # Load manifests
    base_resources = chartify.load_manifests(str(base_file))
    overlay_resources = chartify.load_manifests(str(overlay_file))

    # Verify resource counts
    assert len(base_resources) == 3, f"Expected 3 base resources, got {len(base_resources)}"
    assert len(overlay_resources) == 6, f"Expected 6 overlay resources, got {len(overlay_resources)}"

    # Get resource differences
    resource_diffs = chartify.get_resource_diffs(base_resources, overlay_resources)

    # Analyze the differences
    diff_types = [diff_type for diff_type, _, _ in resource_diffs.values()]
    added_count = diff_types.count('added')
    modified_count = diff_types.count('modified')
    unchanged_count = diff_types.count('unchanged')
    removed_count = diff_types.count('removed')

    # Should have 3 added resources (Redis Deployment, Redis Service, Migration Job)
    # Should have 1 modified resource (ConfigMap with different data)
    # Should have 2 unchanged resources (Deployment, Service)
    assert added_count == 3, f"Expected 3 added resources, got {added_count}"
    assert modified_count == 1, f"Expected 1 modified resource, got {modified_count}"
    assert unchanged_count == 2, f"Expected 2 unchanged resources, got {unchanged_count}"
    assert removed_count == 0, f"Expected 0 removed resources, got {removed_count}"

    # Generate the Helm chart
    condition_key = "global.enableExtensions"
    chartify.create_chart_structure(
        str(output_path),
        "missing-resources-chart",
        condition_key,
        False,  # default condition - extensions disabled by default
        "1.0.0",
        "1.0.0"
    )

    # Generate templates and collect template contents
    template_contents = {}
    added_templates = []
    modified_templates = []
    unchanged_templates = []

    for resource_key, resource_diff in resource_diffs.items():
        diff_type, base_res, overlay_res = resource_diff
        folder, filename, template_content = chartify.generate_helm_template(resource_diff, condition_key)
        chartify.write_template_file(str(output_path), folder, filename, template_content)

        template_contents[resource_key] = template_content

        if diff_type == 'added':
            added_templates.append((resource_key, template_content, overlay_res))
        elif diff_type == 'modified':
            modified_templates.append((resource_key, template_content, base_res, overlay_res))
        elif diff_type == 'unchanged':
            unchanged_templates.append((resource_key, template_content, base_res))

    # Verify added resource templates have correct conditional structure
    assert len(added_templates) == 3, f"Expected 3 added templates, got {len(added_templates)}"

    for resource_key, template_content, resource in added_templates:
        # Added resources should be wrapped in {{- if .Values.condition }}
        assert f"{{{{- if .Values.{condition_key} }}}}" in template_content, f"Added resource {resource_key} should have if condition"
        assert "{{- end }}" in template_content, f"Added resource {resource_key} should have end block"
        assert "{{- else }}" not in template_content, f"Added resource {resource_key} should not have else block"

        # Verify the resource is the overlay version
        resource_name = resource['metadata']['name']
        assert resource_name in ['redis', 'redis-service', 'migration-job'], f"Unexpected added resource: {resource_name}"

    # Verify modified resource template has if/else structure
    assert len(modified_templates) == 1, f"Expected 1 modified template, got {len(modified_templates)}"

    resource_key, template_content, base_res, overlay_res = modified_templates[0]
    assert base_res['metadata']['name'] == 'shared-config', "Modified resource should be shared-config"
    assert f"{{{{- if .Values.{condition_key} }}}}" in template_content, "Modified resource should have if condition"
    assert "{{- else }}" in template_content, "Modified resource should have else block"
    assert "{{- end }}" in template_content, "Modified resource should have end block"

    # Verify unchanged resources have no conditionals
    assert len(unchanged_templates) == 2, f"Expected 2 unchanged templates, got {len(unchanged_templates)}"

    for resource_key, template_content, resource in unchanged_templates:
        assert f"{{{{- if .Values.{condition_key} }}}}" not in template_content, f"Unchanged resource {resource_key} should not have conditionals"
        assert "{{- else }}" not in template_content, f"Unchanged resource {resource_key} should not have else"
        assert "{{- end }}" not in template_content, f"Unchanged resource {resource_key} should not have end"

        # Should be plain YAML
        resource_name = resource['metadata']['name']
        assert resource_name in ['web-app', 'web-app-service'], f"Unexpected unchanged resource: {resource_name}"

    # Verify chart structure
    chart_yaml_path = output_path / "Chart.yaml"
    values_yaml_path = output_path / "values.yaml"
    templates_dir = output_path / "templates"

    assert chart_yaml_path.exists(), "Chart.yaml should exist"
    assert values_yaml_path.exists(), "values.yaml should exist"
    assert templates_dir.exists(), "templates directory should exist"

    # Verify values.yaml has the correct structure
    with open(values_yaml_path) as f:
        values_data = yaml.safe_load(f)
        assert 'global' in values_data
        assert 'enableExtensions' in values_data['global']
        assert values_data['global']['enableExtensions'] is False

    # Verify correct number of template files
    template_files = list(templates_dir.glob("*.yaml"))
    assert len(template_files) == 6, f"Expected 6 template files, got {len(template_files)}"


def test_removed_resources(assets_dir, temp_chart_dir):
    """
    Test handling of resources that are removed in the overlay.

    This test verifies:
    - Base has 4 resources: Deployment, Service, Legacy Deployment, Legacy ConfigMap
    - Overlay has 2 resources: Deployment, Service (legacy resources removed)
    - Removed resources get {{- if not .Values.condition }} wrapper
    """
    # Get paths to test assets
    base_file = assets_dir / "base-with-removed.yaml"
    overlay_file = assets_dir / "overlay-with-removed.yaml"

    # Verify test assets exist
    assert base_file.exists(), f"Base test asset not found: {base_file}"
    assert overlay_file.exists(), f"Overlay test asset not found: {overlay_file}"

    output_path = temp_chart_dir / "removed-resources-chart"

    # Load manifests
    base_resources = chartify.load_manifests(str(base_file))
    overlay_resources = chartify.load_manifests(str(overlay_file))

    # Verify resource counts
    assert len(base_resources) == 4, f"Expected 4 base resources, got {len(base_resources)}"
    assert len(overlay_resources) == 2, f"Expected 2 overlay resources, got {len(overlay_resources)}"

    # Get resource differences
    resource_diffs = chartify.get_resource_diffs(base_resources, overlay_resources)

    # Analyze the differences
    diff_types = [diff_type for diff_type, _, _ in resource_diffs.values()]
    added_count = diff_types.count('added')
    modified_count = diff_types.count('modified')
    unchanged_count = diff_types.count('unchanged')
    removed_count = diff_types.count('removed')

    # Should have 2 removed resources (Legacy Deployment, Legacy ConfigMap)
    # Should have 2 unchanged resources (main Deployment, Service)
    assert added_count == 0, f"Expected 0 added resources, got {added_count}"
    assert modified_count == 0, f"Expected 0 modified resources, got {modified_count}"
    assert unchanged_count == 2, f"Expected 2 unchanged resources, got {unchanged_count}"
    assert removed_count == 2, f"Expected 2 removed resources, got {removed_count}"

    # Generate the Helm chart
    condition_key = "global.enableLegacyServices"
    chartify.create_chart_structure(
        str(output_path),
        "removed-resources-chart",
        condition_key,
        True,  # default condition - legacy services enabled by default
        "1.0.0",
        "1.0.0"
    )

    # Generate templates and collect template contents
    removed_templates = []
    unchanged_templates = []

    for resource_key, resource_diff in resource_diffs.items():
        diff_type, base_res, overlay_res = resource_diff
        folder, filename, template_content = chartify.generate_helm_template(resource_diff, condition_key)
        chartify.write_template_file(str(output_path), folder, filename, template_content)

        if diff_type == 'removed':
            removed_templates.append((resource_key, template_content, base_res))
        elif diff_type == 'unchanged':
            unchanged_templates.append((resource_key, template_content, base_res))

    # Verify removed resource templates have correct conditional structure
    assert len(removed_templates) == 2, f"Expected 2 removed templates, got {len(removed_templates)}"

    for resource_key, template_content, resource in removed_templates:
        # Removed resources should be wrapped in {{- if not .Values.condition }}
        assert f"{{{{- if not .Values.{condition_key} }}}}" in template_content, f"Removed resource {resource_key} should have 'if not' condition"
        assert "{{- end }}" in template_content, f"Removed resource {resource_key} should have end block"
        assert "{{- else }}" not in template_content, f"Removed resource {resource_key} should not have else block"

        # Verify the resource is from the base (the removed resource)
        resource_name = resource['metadata']['name']
        assert resource_name in ['legacy-service', 'legacy-config'], f"Unexpected removed resource: {resource_name}"

    # Verify unchanged resources have no conditionals
    assert len(unchanged_templates) == 2, f"Expected 2 unchanged templates, got {len(unchanged_templates)}"

    for resource_key, template_content, resource in unchanged_templates:
        assert f"{{{{- if .Values.{condition_key} }}}}" not in template_content, f"Unchanged resource {resource_key} should not have conditionals"
        assert f"{{{{- if not .Values.{condition_key} }}}}" not in template_content, f"Unchanged resource {resource_key} should not have 'if not' conditionals"
        assert "{{- else }}" not in template_content, f"Unchanged resource {resource_key} should not have else"
        assert "{{- end }}" not in template_content, f"Unchanged resource {resource_key} should not have end"

        # Should be plain YAML
        resource_name = resource['metadata']['name']
        assert resource_name in ['web-app', 'web-app-service'], f"Unexpected unchanged resource: {resource_name}"

    # Verify chart structure
    chart_yaml_path = output_path / "Chart.yaml"
    values_yaml_path = output_path / "values.yaml"
    templates_dir = output_path / "templates"

    assert chart_yaml_path.exists(), "Chart.yaml should exist"
    assert values_yaml_path.exists(), "values.yaml should exist"
    assert templates_dir.exists(), "templates directory should exist"

    # Verify values.yaml has the correct structure
    with open(values_yaml_path) as f:
        values_data = yaml.safe_load(f)
        assert 'global' in values_data
        assert 'enableLegacyServices' in values_data['global']
        assert values_data['global']['enableLegacyServices'] is True

    # Verify correct number of template files
    template_files = list(templates_dir.glob("*.yaml"))
    assert len(template_files) == 4, f"Expected 4 template files, got {len(template_files)}"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
