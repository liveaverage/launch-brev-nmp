#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_from_directory, Response, stream_with_context
import subprocess
import os
import json
import logging
import time
import threading
import queue
from dataclasses import dataclass, field
from typing import Optional, List
from datetime import datetime

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Global deployment state - singleton tracker for the current/last deployment
@dataclass
class DeploymentState:
    """Tracks the state of the current or most recent deployment"""
    is_running: bool = False
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None
    status: str = "idle"  # idle, running, success, failed, timeout
    logs: List[dict] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)
    
    def start(self):
        with self.lock:
            self.is_running = True
            self.started_at = datetime.now()
            self.finished_at = None
            self.status = "running"
            self.logs = []
    
    def add_log(self, log_entry: dict):
        with self.lock:
            self.logs.append(log_entry)
    
    def finish(self, status: str):
        with self.lock:
            self.is_running = False
            self.finished_at = datetime.now()
            self.status = status
    
    def get_logs(self) -> List[dict]:
        with self.lock:
            return list(self.logs)
    
    def get_status(self) -> dict:
        with self.lock:
            return {
                "is_running": self.is_running,
                "status": self.status,
                "started_at": self.started_at.isoformat() if self.started_at else None,
                "finished_at": self.finished_at.isoformat() if self.finished_at else None,
                "log_count": len(self.logs)
            }

# Global singleton
deployment_state = DeploymentState()

# Persistent deployment state file
STATE_FILE = os.environ.get('STATE_FILE', '/app/data/deployment.state')

def get_persistent_state() -> dict:
    """Read persistent deployment state from file"""
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        logger.error(f"Failed to read state file: {e}")
    return {"deployed": False}

def save_persistent_state(state: dict):
    """Write persistent deployment state to file"""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f, indent=2, default=str)
        logger.info(f"State saved: {state.get('status', 'unknown')}")
    except Exception as e:
        logger.error(f"Failed to write state file: {e}")

def clear_persistent_state():
    """Remove persistent state file"""
    try:
        if os.path.exists(STATE_FILE):
            os.remove(STATE_FILE)
            logger.info("State file cleared")
    except Exception as e:
        logger.error(f"Failed to clear state file: {e}")

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
    
    # Get metadata from _meta key
    meta = config.get('_meta', {})
    launcher_path = os.environ.get('LAUNCHER_PATH') or meta.get('launcher_path', '/interlude')
    project_name = os.environ.get('PROJECT_NAME') or meta.get('project_name', 'Interlude')

    # Get the active deployment (first non-meta key, or specified via env)
    active_deploy_type = os.environ.get('DEPLOY_TYPE')

    if not active_deploy_type:
        # Use first non-meta deployment type in config
        deploy_types = [k for k in config.keys() if not k.startswith('_')]
        active_deploy_type = deploy_types[0] if deploy_types else None

    if active_deploy_type and active_deploy_type in config:
        deploy_config = config[active_deploy_type]
        # SHOW_DRY_RUN defaults to false - set to 'true' or '1' to show dry run option
        show_dry_run = os.environ.get('SHOW_DRY_RUN', 'false').lower() in ('true', '1', 'yes')
        
        # Get persistent state
        persistent_state = get_persistent_state()
        
        metadata = {
            'active_deployment': active_deploy_type,
            'versions': deploy_config.get('versions', []),
            'default_version': deploy_config.get('default_version', ''),
            'description': deploy_config.get('description', ''),
            'show_version_selector': len(deploy_config.get('versions', [])) > 0,
            'heading': os.environ.get('DEPLOY_HEADING') or deploy_config.get('heading', 'Deploy'),
            'show_dry_run': show_dry_run,
            'launcher_path': launcher_path,
            'project_name': project_name,
            'has_uninstall': bool(deploy_config.get('uninstall_commands')),
            'deployed': persistent_state.get('deployed', False),
            'deployed_at': persistent_state.get('deployed_at'),
            'deployed_version': persistent_state.get('version')
        }
        return jsonify(metadata)

    return jsonify({'error': 'No deployment configured'}), 500

@app.route('/state', methods=['GET'])
def get_state():
    """Return current deployment state (persistent + in-memory)"""
    persistent = get_persistent_state()
    runtime = deployment_state.get_status()
    return jsonify({
        'persistent': persistent,
        'runtime': runtime
    })

@app.route('/help', methods=['GET'])
def get_help():
    """Return help content"""
    return jsonify(load_help_content())

@app.route('/deploy/status', methods=['GET'])
def deploy_status():
    """Return current deployment status and allow clients to check if deployment is running"""
    return jsonify(deployment_state.get_status())

@app.route('/deploy/logs', methods=['GET'])
def deploy_logs():
    """Stream existing logs and continue with live updates if deployment is running"""
    def generate():
        # First, replay all existing logs
        existing_logs = deployment_state.get_logs()
        last_index = len(existing_logs)
        
        for log_entry in existing_logs:
            yield f"data: {json.dumps(log_entry)}\n\n"
        
        # If deployment is still running, continue streaming new logs
        while deployment_state.is_running:
            yield ": keepalive\n\n"
            time.sleep(1)
            
            # Check for new logs
            current_logs = deployment_state.get_logs()
            if len(current_logs) > last_index:
                for log_entry in current_logs[last_index:]:
                    yield f"data: {json.dumps(log_entry)}\n\n"
                last_index = len(current_logs)
        
        # Send any final logs that came in
        final_logs = deployment_state.get_logs()
        if len(final_logs) > last_index:
            for log_entry in final_logs[last_index:]:
                yield f"data: {json.dumps(log_entry)}\n\n"
        
        # Signal completion
        yield f"data: {json.dumps({'type': 'stream_end', 'status': deployment_state.status})}\n\n"
    
    return Response(stream_with_context(generate()), mimetype='text/event-stream')

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
    def emit_log(log_entry):
        """Helper to emit log and store in global state"""
        deployment_state.add_log(log_entry)
        return f"data: {json.dumps(log_entry)}\n\n"
    
    def generate():
        try:
            data = request.get_json()
            api_key = data.get('apiKey')
            version = data.get('version', '')
            platform_url = data.get('platformUrl', '')

            if not api_key:
                yield f"data: {json.dumps({'type': 'error', 'message': 'API key is required'})}\n\n"
                return

            # Check if deployment is already running
            if deployment_state.is_running:
                yield f"data: {json.dumps({'type': 'info', 'message': 'Deployment already in progress. Connecting to existing logs...'})}\n\n"
                # Redirect to log streaming
                existing_logs = deployment_state.get_logs()
                for log_entry in existing_logs:
                    yield f"data: {json.dumps(log_entry)}\n\n"
                # Continue streaming while running
                last_index = len(existing_logs)
                while deployment_state.is_running:
                    yield ": keepalive\n\n"
                    time.sleep(1)
                    current_logs = deployment_state.get_logs()
                    if len(current_logs) > last_index:
                        for log_entry in current_logs[last_index:]:
                            yield f"data: {json.dumps(log_entry)}\n\n"
                        last_index = len(current_logs)
                # Final logs
                final_logs = deployment_state.get_logs()
                for log_entry in final_logs[last_index:]:
                    yield f"data: {json.dumps(log_entry)}\n\n"
                return

            # Start new deployment
            deployment_state.start()

            # Load configuration
            config = load_config()
            deploy_type = os.environ.get('DEPLOY_TYPE')

            if not deploy_type:
                # Use first non-meta deployment type
                deploy_types = [k for k in config.keys() if not k.startswith('_')]
                deploy_type = deploy_types[0] if deploy_types else None

            if not deploy_type or deploy_type not in config:
                yield emit_log({'type': 'error', 'message': 'No deployment configured'})
                deployment_state.finish('failed')
                return

            deploy_config = config[deploy_type]
            working_dir = deploy_config.get('working_dir', '.')
            env_var = deploy_config.get('env_var', 'NGC_API_KEY')
            pre_commands = deploy_config.get('pre_commands', [])
            command = deploy_config.get('command')
            post_commands = deploy_config.get('post_commands', [])
            log_sources = deploy_config.get('log_sources', [])
            namespace = deploy_config.get('namespace', 'nemo')

            # Prepare environment
            env = os.environ.copy()
            env[env_var] = api_key
            env['VERSION'] = version or deploy_config.get('default_version', '')
            env['PLATFORM_URL'] = platform_url

            # Create queue for streaming
            log_queue = queue.Queue()

            yield emit_log({'type': 'start', 'message': f'Starting {deploy_type} deployment...'})

            # Execute pre-commands (synchronously)
            for idx, pre_cmd in enumerate(pre_commands, 1):
                yield emit_log({'type': 'section', 'message': f'Pre-command {idx}/{len(pre_commands)}'})
                yield emit_log({'type': 'command', 'message': pre_cmd})

                result = execute_command(pre_cmd, working_dir, env, timeout=600, stream_queue=log_queue)

                # Send queued output
                while not log_queue.empty():
                    msg_type, msg = log_queue.get()
                    yield emit_log({'type': msg_type, 'message': msg})

                if result.returncode != 0:
                    yield emit_log({'type': 'error', 'message': f'Pre-command failed with exit code {result.returncode}'})
                    yield emit_log({'type': 'error', 'message': result.stdout if hasattr(result, 'stdout') else 'Unknown error'})
                    deployment_state.finish('failed')
                    return

            # Execute main command asynchronously while monitoring pods
            yield emit_log({'type': 'section', 'message': 'Main Deployment'})
            yield emit_log({'type': 'command', 'message': command})

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
            max_monitor_time = 900  # 15 minutes max monitoring
            start_time = time.time()
            timed_out = False

            while not result_holder['done'] or polls_without_change < 2:
                # Send keepalive comment (SSE spec: lines starting with : are comments)
                yield ": keepalive\n\n"
                
                # Drain any output from the command
                while not log_queue.empty():
                    try:
                        msg_type, msg = log_queue.get_nowait()
                        yield emit_log({'type': msg_type, 'message': msg})
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
                        yield emit_log({'type': 'pods', 'message': '📦 Pod Status:'})
                        for line in pod_status.split('\n')[:15]:  # Limit to 15 pods
                            if line.strip():
                                yield emit_log({'type': 'pod', 'message': line})
                        last_pod_status = pod_status
                except Exception as e:
                    logger.debug(f"Pod poll error: {e}")

                # Timeout check
                if time.time() - start_time > max_monitor_time:
                    yield emit_log({'type': 'info', 'message': 'Monitoring timeout reached (15 min). Helm may still be running in background.'})
                    yield emit_log({'type': 'info', 'message': 'Check status with: kubectl get pods -n nemo'})
                    timed_out = True
                    break

                time.sleep(poll_interval)

            # Wait for thread to complete (longer timeout if we didn't timeout on monitoring)
            if not timed_out:
                cmd_thread.join(timeout=30)
            else:
                cmd_thread.join(timeout=5)  # Brief wait if we already timed out

            # Final drain of output
            while not log_queue.empty():
                try:
                    msg_type, msg = log_queue.get_nowait()
                    yield emit_log({'type': msg_type, 'message': msg})
                except:
                    break

            # Report final status
            if timed_out and result_holder['returncode'] is None:
                # Monitoring timed out but helm is still running - not a failure
                yield emit_log({'type': 'info', 'message': 'Helm install is running in background. Monitor with:'})
                yield emit_log({'type': 'command', 'message': 'watch kubectl get pods -n nemo'})
                yield emit_log({'type': 'complete'})
                deployment_state.finish('timeout')
            elif result_holder['returncode'] == 0:
                yield emit_log({'type': 'success', 'message': 'Helm install command completed successfully!'})

                # Execute post-commands (e.g., start reverse proxy)
                if post_commands:
                    yield emit_log({'type': 'section', 'message': 'Post-deployment setup'})
                    for idx, post_cmd in enumerate(post_commands, 1):
                        yield emit_log({'type': 'info', 'message': f'Post-command {idx}/{len(post_commands)}'})
                        yield emit_log({'type': 'command', 'message': post_cmd})
                        
                        result = execute_command(post_cmd, working_dir, env, timeout=120, stream_queue=log_queue)
                        
                        # Send queued output
                        while not log_queue.empty():
                            msg_type, msg = log_queue.get()
                            yield emit_log({'type': msg_type, 'message': msg})
                        
                        if result.returncode != 0:
                            yield emit_log({'type': 'warning', 'message': f'Post-command exited with code {result.returncode} (non-fatal)'})
                        else:
                            yield emit_log({'type': 'success', 'message': f'Post-command completed'})

                # Success message with links
                yield emit_log({'type': 'section', 'message': '🎉 Deployment Complete!'})
                yield emit_log({'type': 'success', 'message': 'NeMo Microservices are now running.'})
                yield emit_log({'type': 'info', 'message': ''})
                yield emit_log({'type': 'link', 'message': 'Open NeMo Studio', 'url': '/studio'})
                yield emit_log({'type': 'link', 'message': 'View Deployment Status', 'url': '/interlude'})
                yield emit_log({'type': 'info', 'message': ''})
                yield emit_log({'type': 'info', 'message': 'Note: Some pods may still be starting. Check /studio in a few minutes if not ready.'})

                # Save persistent state on success
                save_persistent_state({
                    'deployed': True,
                    'status': 'success',
                    'deploy_type': deploy_type,
                    'version': env.get('VERSION', ''),
                    'deployed_at': datetime.now().isoformat(),
                    'namespace': namespace
                })
                
                yield emit_log({'type': 'complete'})
                deployment_state.finish('success')
            elif result_holder['returncode'] is None:
                # Command still running but not timed out - unusual state
                yield emit_log({'type': 'info', 'message': 'Deployment status unknown. Check manually:'})
                yield emit_log({'type': 'command', 'message': 'kubectl get pods -n nemo'})
                yield emit_log({'type': 'complete'})
                deployment_state.finish('unknown')
            else:
                error_output = result_holder.get('stdout', 'Unknown error')
                exit_code = result_holder['returncode']
                yield emit_log({'type': 'error', 'message': f'Deployment failed with exit code {exit_code}'})
                # Show the actual error from helm
                if error_output:
                    for line in error_output.split('\n')[-20:]:  # Last 20 lines
                        if line.strip():
                            yield emit_log({'type': 'error', 'message': line})
                deployment_state.finish('failed')

        except Exception as e:
            logger.error(f"Streaming error: {str(e)}")
            yield emit_log({'type': 'error', 'message': f'Error: {str(e)}'})
            deployment_state.finish('failed')

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
            # Use first non-meta deployment type
            deploy_types = [k for k in config.keys() if not k.startswith('_')]
            deploy_type = deploy_types[0] if deploy_types else None

        if not deploy_type or deploy_type not in config:
            return jsonify({'error': 'No deployment configured'}), 500

        deploy_config = config[deploy_type]
        working_dir = deploy_config.get('working_dir', '/app')
        env_var = deploy_config.get('env_var', 'NGC_API_KEY')
        pre_commands = deploy_config.get('pre_commands', [])
        post_commands = deploy_config.get('post_commands', [])
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
                    'main_command': mask_secrets(command),
                    'post_commands': [mask_secrets(cmd) for cmd in post_commands]
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

@app.route('/uninstall', methods=['POST'])
def uninstall():
    """Uninstall the deployed application"""
    try:
        # Check if we're deployed
        persistent_state = get_persistent_state()
        if not persistent_state.get('deployed'):
            return jsonify({'error': 'Nothing to uninstall'}), 400
        
        config = load_config()
        deploy_type = persistent_state.get('deploy_type')
        
        if not deploy_type or deploy_type not in config:
            # Fall back to first deploy type
            deploy_types = [k for k in config.keys() if not k.startswith('_')]
            deploy_type = deploy_types[0] if deploy_types else None
        
        if not deploy_type:
            return jsonify({'error': 'No deployment type configured'}), 500
        
        deploy_config = config[deploy_type]
        uninstall_commands = deploy_config.get('uninstall_commands', [])
        
        if not uninstall_commands:
            return jsonify({'error': 'No uninstall commands configured'}), 400
        
        working_dir = deploy_config.get('working_dir', '.')
        env = os.environ.copy()
        
        outputs = []
        for cmd in uninstall_commands:
            logger.info(f"Uninstall command: {cmd}")
            result = execute_command(cmd, working_dir, env, timeout=120)
            outputs.append(result.stdout)
            
            if result.returncode != 0:
                logger.warning(f"Uninstall command returned {result.returncode}: {result.stderr}")
                # Continue with other commands even if one fails
        
        # Clear persistent state
        clear_persistent_state()
        
        return jsonify({
            'message': 'Uninstall completed',
            'output': '\n'.join(outputs)
        }), 200
        
    except Exception as e:
        logger.error(f"Uninstall error: {str(e)}")
        return jsonify({'error': f'Uninstall error: {str(e)}'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
