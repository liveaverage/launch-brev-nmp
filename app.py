#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_from_directory, Response, stream_with_context
import subprocess
import os
import json
import logging
import time
import threading
import queue

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Store for active log streams
active_streams = {}

# Load configuration
# Use local paths as default, Docker paths as fallback
def get_config_path():
    default = './config.json'
    if os.path.exists(default):
        return default
    return os.environ.get('CONFIG_FILE', '/app/config.json')

def get_help_path():
    default = './help-content.json'
    if os.path.exists(default):
        return default
    return os.environ.get('HELP_CONTENT_FILE', '/app/help-content.json')

CONFIG_FILE = os.environ.get('CONFIG_FILE') or get_config_path()
HELP_CONTENT_FILE = os.environ.get('HELP_CONTENT_FILE') or get_help_path()

def load_config():
    """Load configuration from JSON file"""
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        return {
            "docker-compose": {
                "command": "docker-compose up -d",
                "working_dir": "/app",
                "env_var": "NGC_API_KEY"
            },
            "helm": {
                "command": "helm install myrelease ./chart",
                "working_dir": "/app",
                "env_var": "NGC_API_KEY"
            }
        }

def load_help_content():
    """Load help content from JSON file"""
    try:
        with open(HELP_CONTENT_FILE, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.warning(f"Failed to load help content: {e}")
        return {
            "title": "Deployment Guide",
            "sections": [
                {
                    "title": "Getting Started",
                    "content": "Enter your API key and select a deployment type to begin."
                }
            ]
        }

def execute_command(command, working_dir, env, timeout=300, stream_queue=None):
    """Execute a shell command and return result, optionally streaming output"""
    logger.info(f"Executing: {command}")

    if stream_queue is None:
        # Original behavior - capture all output
        result = subprocess.run(
            command,
            shell=True,
            cwd=working_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result

    # Stream output line by line
    process = subprocess.Popen(
        command,
        shell=True,
        cwd=working_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )

    output_lines = []
    try:
        for line in iter(process.stdout.readline, ''):
            if line:
                output_lines.append(line)
                if stream_queue:
                    stream_queue.put(('output', line.rstrip()))

        process.wait(timeout=timeout)

        # Create result object
        class Result:
            def __init__(self, returncode, stdout):
                self.returncode = returncode
                self.stdout = stdout
                self.stderr = ''

        return Result(process.returncode, ''.join(output_lines))

    except subprocess.TimeoutExpired:
        process.kill()
        raise
    finally:
        if process.stdout:
            process.stdout.close()

@app.route('/')
def index():
    """Serve the main HTML page"""
    return send_from_directory('.', 'index.html')

@app.route('/assets/<path:filename>')
def assets(filename):
    """Serve static assets"""
    return send_from_directory('assets', filename)

@app.route('/config', methods=['GET'])
def get_config():
    """Return deployment configuration metadata"""
    config = load_config()

    # Get the active deployment (first one in config, or specified via env)
    active_deploy_type = os.environ.get('DEPLOY_TYPE')

    if not active_deploy_type:
        # Use first deployment type in config
        active_deploy_type = list(config.keys())[0] if config else None

    if active_deploy_type and active_deploy_type in config:
        deploy_config = config[active_deploy_type]
        metadata = {
            'active_deployment': active_deploy_type,
            'versions': deploy_config.get('versions', []),
            'default_version': deploy_config.get('default_version', ''),
            'description': deploy_config.get('description', ''),
            'show_version_selector': len(deploy_config.get('versions', [])) > 0,
            'heading': os.environ.get('DEPLOY_HEADING') or deploy_config.get('heading', 'Deploy')
        }
        return jsonify(metadata)

    return jsonify({'error': 'No deployment configured'}), 500

@app.route('/help', methods=['GET'])
def get_help():
    """Return help content"""
    return jsonify(load_help_content())

def run_command_async(command, working_dir, env, result_holder, output_queue):
    """Run a command in a thread, putting output lines in queue"""
    try:
        process = subprocess.Popen(
            command,
            shell=True,
            cwd=working_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        output_lines = []
        for line in iter(process.stdout.readline, ''):
            if line:
                output_lines.append(line)
                output_queue.put(('output', line.rstrip()))
        
        process.wait()
        process.stdout.close()
        
        result_holder['returncode'] = process.returncode
        result_holder['stdout'] = ''.join(output_lines)
        result_holder['done'] = True
    except Exception as e:
        result_holder['returncode'] = 1
        result_holder['stdout'] = str(e)
        result_holder['done'] = True
        output_queue.put(('error', f'Command error: {str(e)}'))


@app.route('/deploy/stream', methods=['POST'])
def deploy_stream():
    """Handle deployment with real-time log streaming via SSE"""
    def generate():
        try:
            data = request.get_json()
            api_key = data.get('apiKey')
            version = data.get('version', '')

            if not api_key:
                yield f"data: {json.dumps({'type': 'error', 'message': 'API key is required'})}\n\n"
                return

            # Load configuration
            config = load_config()
            deploy_type = os.environ.get('DEPLOY_TYPE')

            if not deploy_type:
                deploy_type = list(config.keys())[0] if config else None

            if not deploy_type or deploy_type not in config:
                yield f"data: {json.dumps({'type': 'error', 'message': 'No deployment configured'})}\n\n"
                return

            deploy_config = config[deploy_type]
            working_dir = deploy_config.get('working_dir', '.')
            env_var = deploy_config.get('env_var', 'NGC_API_KEY')
            pre_commands = deploy_config.get('pre_commands', [])
            command = deploy_config.get('command')
            log_sources = deploy_config.get('log_sources', [])
            namespace = deploy_config.get('namespace', 'nemo')

            # Prepare environment
            env = os.environ.copy()
            env[env_var] = api_key
            env['VERSION'] = version or deploy_config.get('default_version', '')

            # Create queue for streaming
            log_queue = queue.Queue()

            yield f"data: {json.dumps({'type': 'start', 'message': f'Starting {deploy_type} deployment...'})}\n\n"

            # Execute pre-commands (synchronously)
            for idx, pre_cmd in enumerate(pre_commands, 1):
                yield f"data: {json.dumps({'type': 'section', 'message': f'Pre-command {idx}/{len(pre_commands)}'})}\n\n"
                yield f"data: {json.dumps({'type': 'command', 'message': pre_cmd})}\n\n"

                result = execute_command(pre_cmd, working_dir, env, timeout=600, stream_queue=log_queue)

                # Send queued output
                while not log_queue.empty():
                    msg_type, msg = log_queue.get()
                    yield f"data: {json.dumps({'type': msg_type, 'message': msg})}\n\n"

                if result.returncode != 0:
                    yield f"data: {json.dumps({'type': 'error', 'message': f'Pre-command failed with exit code {result.returncode}'})}\n\n"
                    yield f"data: {json.dumps({'type': 'error', 'message': result.stdout if hasattr(result, 'stdout') else 'Unknown error'})}\n\n"
                    return

            # Execute main command asynchronously while monitoring pods
            yield f"data: {json.dumps({'type': 'section', 'message': 'Main Deployment'})}\n\n"
            yield f"data: {json.dumps({'type': 'command', 'message': command})}\n\n"

            # Start helm install in background thread
            result_holder = {'done': False, 'returncode': None, 'stdout': ''}
            cmd_thread = threading.Thread(
                target=run_command_async,
                args=(command, working_dir, env, result_holder, log_queue)
            )
            cmd_thread.start()

            # Monitor pods while helm runs
            poll_interval = 5
            last_pod_status = ""
            polls_without_change = 0
            max_monitor_time = 300  # 5 minutes max monitoring
            start_time = time.time()

            while not result_holder['done'] or polls_without_change < 2:
                # Send keepalive comment (SSE spec: lines starting with : are comments)
                yield ": keepalive\n\n"
                
                # Drain any output from the command
                while not log_queue.empty():
                    try:
                        msg_type, msg = log_queue.get_nowait()
                        yield f"data: {json.dumps({'type': msg_type, 'message': msg})}\n\n"
                    except:
                        break

                # Check if command is done
                if result_holder['done']:
                    polls_without_change += 1
                    if polls_without_change >= 2:
                        break

                # Poll pod status
                try:
                    pod_result = subprocess.run(
                        f"kubectl get pods -n {namespace} --no-headers 2>/dev/null | head -20",
                        shell=True,
                        capture_output=True,
                        text=True,
                        timeout=10,
                        env=env
                    )
                    pod_status = pod_result.stdout.strip()
                    
                    if pod_status and pod_status != last_pod_status:
                        yield f"data: {json.dumps({'type': 'pods', 'message': '📦 Pod Status:'})}\n\n"
                        for line in pod_status.split('\n')[:15]:  # Limit to 15 pods
                            if line.strip():
                                yield f"data: {json.dumps({'type': 'pod', 'message': line})}\n\n"
                        last_pod_status = pod_status
                except Exception as e:
                    logger.debug(f"Pod poll error: {e}")

                # Timeout check
                if time.time() - start_time > max_monitor_time:
                    yield f"data: {json.dumps({'type': 'info', 'message': 'Monitoring timeout reached, deployment may still be in progress'})}\n\n"
                    break

                time.sleep(poll_interval)

            # Wait for thread to complete
            cmd_thread.join(timeout=10)

            # Final drain of output
            while not log_queue.empty():
                try:
                    msg_type, msg = log_queue.get_nowait()
                    yield f"data: {json.dumps({'type': msg_type, 'message': msg})}\n\n"
                except:
                    break

            # Report final status
            if result_holder['returncode'] == 0:
                yield f"data: {json.dumps({'type': 'success', 'message': 'Helm install command completed successfully!'})}\n\n"

                # Final pod status
                yield f"data: {json.dumps({'type': 'section', 'message': 'Final Status'})}\n\n"
                for log_source in log_sources:
                    log_cmd = log_source.get('command', '').replace('${VERSION}', env['VERSION'])
                    log_label = log_source.get('label', 'Status')
                    
                    yield f"data: {json.dumps({'type': 'info', 'message': f'--- {log_label} ---'})}\n\n"
                    
                    try:
                        log_result = subprocess.run(
                            log_cmd, shell=True, capture_output=True, text=True, timeout=30, env=env
                        )
                        for line in log_result.stdout.strip().split('\n'):
                            if line.strip():
                                yield f"data: {json.dumps({'type': 'log', 'message': line})}\n\n"
                    except Exception as e:
                        yield f"data: {json.dumps({'type': 'error', 'message': f'Failed to get {log_label}: {e}'})}\n\n"

                yield f"data: {json.dumps({'type': 'complete'})}\n\n"
            else:
                error_output = result_holder.get('stdout', 'Unknown error')
                yield f"data: {json.dumps({'type': 'error', 'message': f'Deployment failed with exit code {result_holder[\"returncode\"]}'})}\n\n"
                # Show the actual error from helm
                if error_output:
                    for line in error_output.split('\n')[-20:]:  # Last 20 lines
                        if line.strip():
                            yield f"data: {json.dumps({'type': 'error', 'message': line})}\n\n"

        except Exception as e:
            logger.error(f"Streaming error: {str(e)}")
            yield f"data: {json.dumps({'type': 'error', 'message': f'Error: {str(e)}'})}\n\n"

    return Response(stream_with_context(generate()), mimetype='text/event-stream')

@app.route('/deploy', methods=['POST'])
def deploy():
    """Handle deployment request"""
    try:
        data = request.get_json()
        api_key = data.get('apiKey')
        version = data.get('version', '')
        dry_run = data.get('dryRun', False) or os.environ.get('DRY_RUN', '').lower() == 'true'

        if not api_key:
            return jsonify({'error': 'API key is required'}), 400

        # Load configuration and get active deployment
        config = load_config()
        deploy_type = os.environ.get('DEPLOY_TYPE')

        if not deploy_type:
            # Use first deployment type in config
            deploy_type = list(config.keys())[0] if config else None

        if not deploy_type or deploy_type not in config:
            return jsonify({'error': 'No deployment configured'}), 500

        deploy_config = config[deploy_type]
        working_dir = deploy_config.get('working_dir', '/app')
        env_var = deploy_config.get('env_var', 'NGC_API_KEY')
        pre_commands = deploy_config.get('pre_commands', [])
        command = deploy_config.get('command')

        # Prepare environment variables
        env = os.environ.copy()
        env[env_var] = api_key
        env['VERSION'] = version or deploy_config.get('default_version', '')

        logger.info(f"{'DRY RUN: ' if dry_run else ''}Executing deployment: {deploy_type}")
        logger.info(f"Version: {env['VERSION']}")
        logger.info(f"Working directory: {working_dir}")

        # Dry-run mode: return what would be executed
        if dry_run:
            def mask_secrets(cmd_str):
                """Mask API keys and passwords in commands"""
                masked = cmd_str.replace(api_key, '***')
                # Also mask common password patterns
                import re
                masked = re.sub(r'(--password[=\s]+)[^\s]+', r'\1***', masked)
                masked = re.sub(r'(password[=:]["\']?)[^"\'>\s]+', r'\1***', masked)
                return masked

            dry_run_info = {
                'dry_run': True,
                'would_execute': {
                    'deployment_type': deploy_type,
                    'version': env['VERSION'],
                    'working_directory': working_dir,
                    'environment': {
                        env_var: '***hidden***',
                        'VERSION': env['VERSION']
                    },
                    'pre_commands': [mask_secrets(cmd) for cmd in pre_commands],
                    'main_command': mask_secrets(command)
                },
                'message': 'Dry run complete - no commands were executed'
            }
            logger.info("Dry run completed successfully")
            return jsonify(dry_run_info), 200

        outputs = []

        # Execute pre-commands (e.g., helm fetch)
        for pre_cmd in pre_commands:
            logger.info(f"Pre-command: {pre_cmd}")
            result = execute_command(pre_cmd, working_dir, env, timeout=600)
            outputs.append(f"Pre-command output: {result.stdout}")

            if result.returncode != 0:
                logger.error(f"Pre-command failed: {result.stderr}")
                return jsonify({
                    'error': f'Pre-command failed: {result.stderr}',
                    'output': '\n'.join(outputs)
                }), 500

        # Execute the main deployment command
        logger.info(f"Main command: {command}")
        result = execute_command(command, working_dir, env, timeout=600)
        outputs.append(result.stdout)

        if result.returncode == 0:
            logger.info(f"Deployment successful")
            return jsonify({
                'message': f'{deploy_type.title()} deployment initiated successfully!',
                'output': '\n'.join(outputs)
            }), 200
        else:
            logger.error(f"Deployment failed: {result.stderr}")
            return jsonify({
                'error': f'Deployment failed: {result.stderr}',
                'output': '\n'.join(outputs)
            }), 500

    except subprocess.TimeoutExpired:
        logger.error("Deployment timed out")
        return jsonify({'error': 'Deployment timed out after 10 minutes'}), 500
    except Exception as e:
        logger.error(f"Deployment error: {str(e)}")
        return jsonify({'error': f'Deployment error: {str(e)}'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
