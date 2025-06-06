import os
import pexpect # For interacting with the gamdl CLI
from flask import Flask, render_template, request # request is used by socketio for sid
from flask_socketio import SocketIO, emit, join_room, leave_room # For WebSocket communication
# dotenv is no longer used for these paths in Docker context
import threading # For running pexpect reads in a non-blocking way

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24) # Necessary for Flask-SocketIO session management
socketio = SocketIO(app, async_mode='threading') # Using threading for async operations

# Configuration paths are fixed for Docker.
# Users should use volume mounts in docker-compose.yml to provide these.
GAMDL_COOKIES_PATH = "/app/config/cookies.txt"
GAMDL_OUTPUT_PATH = "/app/music"

# Dictionary to store child Pexpect processes, keyed by session ID (request.sid)
child_processes = {}

@app.route('/', methods=['GET']) # Explicitly state GET, though it's default
def index():
    # The main page is now simpler, dynamic content is handled by WebSockets
    # This route only supports GET requests.
    return render_template('index.html')

# Helper function to read output from gamdl process
def read_gamdl_output(sid, child_process):
    """
    Reads output from the gamdl process and emits it to the client via WebSockets.
    This function is intended to be run in a background thread.
    """
    print(f"Starting gamdl output reader for SID {sid}.")
    try:
        while True:
            try:
                # Read output with a small timeout to avoid blocking indefinitely
                # pexpect.spawn was called with encoding='utf-8', so read_nonblocking returns a string.
                output_str = child_process.read_nonblocking(size=1024, timeout=0.2) # Small timeout
                if output_str: # output_str is already a string
                    socketio.emit('gamdl_output', {'data': output_str}, room=sid)
            except pexpect.TIMEOUT:
                # This is expected if there's no output. Check if process is alive.
                if not child_process.isalive():
                    socketio.emit('info_message', {'message': 'gamdl process appears to have exited.'}, room=sid)
                    print(f"Gamdl process for SID {sid} exited (not alive).")
                    break
                continue # Continue loop, waiting for more output
            except pexpect.EOF:
                # End Of File means the process has terminated.
                socketio.emit('info_message', {'message': 'gamdl process finished (EOF).'}, room=sid)
                print(f"Gamdl process for SID {sid} finished (EOF).")
                break # Exit the loop
            except Exception as e:
                # Catch any other exceptions during read
                error_msg = f"Error reading gamdl output for SID {sid}: {str(e)}"
                print(error_msg)
                socketio.emit('error_message', {'error': error_msg}, room=sid)
                break # Exit the loop
    finally:
        # Ensure cleanup happens regardless of how the loop exits
        if child_process.isalive():
            print(f"Closing pexpect child for SID {sid}.")
            child_process.close() # Close the connection to the child
        if sid in child_processes:
            print(f"Removing SID {sid} from child_processes.")
            del child_processes[sid] # Remove from active processes
        # Notify client that the process is fully done and cleaned up
        socketio.emit('download_complete', {'message': 'Download process and cleanup finished.'}, room=sid)
        print(f"Gamdl output thread for SID {sid} finished.")

@socketio.on('connect')
def handle_connect():
    sid = request.sid
    join_room(sid) # Each client joins a room identified by their session ID
    print(f"Client connected: {sid}")
    # GAMDL_COOKIES_PATH and GAMDL_OUTPUT_PATH are now hardcoded,
    # so no check is needed here for them being set.

@socketio.on('disconnect')
def handle_disconnect():
    sid = request.sid
    print(f"Client disconnected: {sid}")
    child_process = child_processes.pop(sid, None) # Remove and get process
    if child_process and child_process.isalive():
        print(f"Terminating gamdl process for SID {sid} due to disconnect.")
        try:
            # Attempt graceful shutdown first
            if child_process.isalive(): child_process.sendeof() # Ctrl+D, might close some interactive prompts
            socketio.sleep(0.1) # Give a moment for EOF to be processed
            if child_process.isalive(): child_process.terminate(force=False) # SIGTERM
            socketio.sleep(0.1) # Give a moment for SIGTERM
            if child_process.isalive(): child_process.terminate(force=True) # SIGKILL
        except Exception as e:
            print(f"Error terminating process for SID {sid}: {str(e)}")
    leave_room(sid) # Client leaves their room

@socketio.on('start_download')
def handle_start_download(data_dict):
    sid = request.sid
    if sid in child_processes and child_processes[sid].isalive():
        emit('error_message', {'error': 'A download process is already running for your session.'}, room=sid)
        return

    # GAMDL_COOKIES_PATH and GAMDL_OUTPUT_PATH are now hardcoded,
    # so no check is needed here for them being set.

    apple_music_url = data_dict.get('url')
    if not apple_music_url:
        emit('error_message', {'error': 'No Apple Music URL provided.'}, room=sid)
        return

    try:
        gamdl_command_args = [
            '--cookies-path', GAMDL_COOKIES_PATH,
            '--output-path', GAMDL_OUTPUT_PATH,
            '--mp4decrypt-path', '/usr/local/bin/mp4decrypt', # Path for Bento4 built from source
            apple_music_url
        ]
        
        print(f"Starting gamdl for SID {sid} with command: gamdl {' '.join(gamdl_command_args)}")
        
        # Set terminal dimensions and TERM environment variable for the pty
        # This might help gamdl (or its underlying libraries) better detect terminal capabilities.
        # Dimensions are (rows, cols).
        dimensions = (24, 80) # A common default terminal size
        env = os.environ.copy()
        # Set TERM to xterm-256color, as Xterm.js emulates an xterm-compatible terminal.
        # This provides a rich feature set for gamdl to use.
        env['TERM'] = 'xterm-256color' 

        # echo=False prevents the pty from echoing input back, which we might otherwise read
        child = pexpect.spawn('gamdl', 
                              args=gamdl_command_args, 
                              encoding='utf-8', 
                              timeout=None, 
                              echo=False, 
                              dimensions=dimensions,
                              env=env)
        child_processes[sid] = child

        thread = threading.Thread(target=read_gamdl_output, args=(sid, child))
        thread.daemon = True # Allows main program to exit even if threads are running
        thread.start()
        
        emit('info_message', {'message': f'gamdl process started for {apple_music_url}. Waiting for output...'}, room=sid)

    except pexpect.exceptions.ExceptionPexpect as e:
        error_msg = f"Failed to start gamdl: {str(e)}. Ensure 'gamdl' is installed and in your system's PATH."
        print(error_msg)
        emit('error_message', {'error': error_msg}, room=sid)
        if sid in child_processes: # Clean up if spawn failed but entry was made
            del child_processes[sid]
    except Exception as e:
        error_msg = f"An unexpected error occurred while trying to start gamdl: {str(e)}"
        print(error_msg)
        emit('error_message', {'error': error_msg}, room=sid)
        if sid in child_processes: # Clean up
            del child_processes[sid]

@socketio.on('send_input')
def handle_send_input(data_dict):
    sid = request.sid
    user_input = data_dict.get('input') # Input can be an empty string

    if user_input is None: 
        print(f"Received None input from SID {sid}, not sending.")
        return


    child_process = child_processes.get(sid)
    if child_process and child_process.isalive():
        try:
            print(f"Sending input to gamdl for SID {sid}: '{user_input}'")
            # Use send() instead of sendline() to send raw input, including control characters,
            # without automatically appending a newline. Xterm.js will send Enter as \r.
            child_process.send(user_input) 
        except Exception as e:
            error_msg = f"Error sending input to gamdl for SID {sid}: {str(e)}"
            print(error_msg)
            emit('error_message', {'error': error_msg}, room=sid)
    else:
        # It's possible the process ended just before input was sent
        emit('info_message', {'message': 'No active gamdl process for your session, or process has ended. Input not sent.'}, room=sid)
        print(f"No active process for SID {sid} to send input '{user_input}' to.")

# The following block is for running with the Flask development server.
# In production, a WSGI server like Gunicorn will be used, as configured in the Dockerfile.
# if __name__ == '__main__':
#     if not os.path.exists('templates'):
#         os.makedirs('templates')
#     print("Starting Flask-SocketIO development server...")
#     socketio.run(app, debug=True, host='0.0.0.0', port=5000, use_reloader=False, allow_unsafe_werkzeug=True)
