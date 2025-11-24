#!/bin/bash

# CAPI Helm Chart Testing Framework - Quick Reference
# Usage: rt (from anywhere in the project)

echo "🚀 CAPI Helm Chart Testing Framework"
echo ""

# Check if cluster is running
if kubectl cluster-info &>/dev/null; then
    echo "✅ Kubernetes cluster is running"
    echo ""
    echo "Choose your test option:"
    echo ""
    echo "   A - Full framework test (setup cluster + run all tests)"
    echo "   B - Test just the cluster-api chart" 
    echo "   C - Quick chart validation (fastest option)"
    echo ""
    echo -n "Type A, B, or C: "
    read choice

    case $choice in
        [Aa])
            echo "Running full framework test..."
            cd "$(dirname "$0")/.."
            make quick-test
            ;;
        [Bb])
            echo "Running cluster-api chart test..."
            cd "$(dirname "$0")/.."
            make test-capi
            ;;
        [Cc])
            echo "Running chart validation..."
            cd "$(dirname "$0")/.."
            make validate-charts
            ;;
        *)
            echo "Invalid option. Please run 'rt' again and choose A, B, or C."
            ;;
    esac
else
    echo "❌ No Kubernetes cluster found"
    echo ""
    echo "Choose your option:"
    echo ""
    echo "   S - Setup minikube cluster first"
    echo "   C - Quick chart validation (no cluster needed)"
    echo "   Q - Quit"
    echo ""
    echo -n "Type S, C, or Q: "
    read choice

    case $choice in
        [Ss])
            echo "Setting up minikube cluster..."
            cd "$(dirname "$0")/.."
            make setup-cluster
            if [ $? -eq 0 ]; then
                echo ""
                echo "✅ Cluster ready! Run 'rt' again to run tests."
            else
                echo "❌ Cluster setup failed. Check the error above."
            fi
            ;;
        [Cc])
            echo "Running chart validation..."
            cd "$(dirname "$0")/.."
            make validate-charts
            ;;
        [Qq])
            echo "Goodbye!"
            ;;
        *)
            echo "Invalid option. Please run 'rt' again and choose S, C, or Q."
            ;;
    esac
fi