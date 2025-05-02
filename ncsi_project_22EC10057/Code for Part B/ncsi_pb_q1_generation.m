%% Code for generation of different band sounds
clc;
clear all;
close all;

% Read input speech file
[x, Fs] = audioread('fivewo.wav');
t = 1:1:length(x);

% Plot original signal
subplot(6,1,1);
plot(t, x);
title('Original Speech Signal');

% Parameters
w1 = 250;
w2 = 2000;
sig = zeros([1 length(t)]);
num_band = [1, 2, 4, 8];

% Loop for plotting
for l = 1:length(num_band)
    sig = zeros([1 length(t)]);  % Reset signal for each band condition
    for i = 1:num_band(l)
        y(i,:) = bpf(2, w1, w1 * 8^(1/num_band(l)), Fs, x);
        env(i,:) = abs(hilbert(y(i,:)));
        noise = transpose(0.1 * wgn(length(t), 1, 1));
        sig = sig + env(i,:) .* noise;
        fprintf(" %d", w1);
        w1 = w1 * 8^(1/num_band(l));
    end
    w1 = 250;  % Reset w1 for next band condition
    subplot(6,1,l+1);
    plot(t, sig);
    title(sprintf("Number of bands %d", num_band(l)));
end

% Part for generating the 8-band vocoded output
w1 = 250;  % Reset w1
number = 8;
sig = zeros([1 length(t)]);  % Reset signal
for i = 1:number
    y(i,:) = bpf(2, w1, w1 * 8^(1/number), Fs, x);
    env(i,:) = abs(hilbert(y(i,:)));
    noise = transpose(wgn(length(t), 1, 1));
    n = bpf(2, w1, w1 * 8^(1/number), Fs, noise);
    sig = sig + env(i,:) .* n;
    fprintf(" %d", w1);
    w1 = w1 * 8^(1/number);
end

filename = sprintf('fivewo_op_%dband.wav', number);
audiowrite(filename, sig, Fs);

% Bandpass filter function as provided
function y = bpf(n, w1, w2, fs, x)
    [b, a] = butter(n, [w1, w2] / (fs / 2), 'bandpass');
    y = filter(b, a, x);
end
