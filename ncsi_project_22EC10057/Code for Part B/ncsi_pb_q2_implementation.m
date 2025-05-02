%% Implementation of Part A2 and A3 using 1 and 8 band sounds

%%  Question-2 with 1 band and 8 band sound

filename_wav = 'fivewo_op_8band.wav';
%filename_wav = 'fivewo_op_1band.wav'; % for 1 band sound

% Separating out 'ah', generating different intensity stimuli 

h = (0:1/4:6);
ANF = zeros(1,length(h));
for k = 1:length(h)
    ANF(k) = 100*(2^h(k));
end

tones = zeros(1,25);
for i = 1:25
    tones(i) = 100*(2.0^h(i));
end

intensities = -20:5:100;
[fivewo, fs] = audioread(filename_wav);
fivewo = fivewo' ;
S = 1+round(1.05*fs);
E = 1+round(1.15*fs);
L = length(fivewo);
[y,fs] = audioread(filename_wav,[1+round(1.05*fs),1+round(1.15*fs)]);
y = y';
Fs = 100e3;
rt = 10e-3;
T = 100e-3; % stimulus duration in seconds
tester = [fivewo(1:S) zeros(1,50000) fivewo(S:E) zeros(1,50000) fivewo(E:L)] ;
sound(tester,Fs);
t = (0:length(y)-1)/Fs;
mxpts = length(t);
irpts = rt*Fs;
y(1:irpts) = y(1:irpts) .* ((0:(irpts-1))/irpts); 
y((mxpts-irpts):mxpts) = y((mxpts-irpts):mxpts).*((irpts:-1:0)/irpts);
x = rms(y);
I_rms = 20*log10(x/(20*10^(-6)));
rate_matrix = zeros(25,25); % (frequency, intensity)
rate_matrix2 = zeros(1,25);
Input = zeros(1,length(y));
cohc  = 1.0;   % normal ohc function
cihc  = 1.0;   % normal ihc function
fiberType = 3;
implnt = 0;
nrep = 80;
CF = 550;

psthbinwidth = 0.5e-3;
ahTime = length(y) / Fs ;
for i = 1:25 
    Input = y * 10^((((i-1)*5 -115))/20);
    vihc = catmodel_IHC(Input,CF,nrep,1/Fs,ahTime*2,cohc,cihc); 
    [synout,psth] = catmodel_Synapse(vihc,CF,nrep,1/Fs,fiberType,implnt); 
    rate_matrix2(i) = sum(psth(1:(length(psth)/2)));
end
rate_matrix2 = rate_matrix2 / nrep;
rate_matrix2 = rate_matrix2 / ahTime ;

% Creating the stimuli and generating output

for j = 1:25
% stimulus parameters
stimdb = intensities(j);  % stimulus intensity in dB SPL
    for k = 1:25
        
        disp("Int - " + j + ". Freq - " + k);
        
        F0 = ANF(k);     % stimulus frequency in Hz   

        pin = sqrt(2)*20e-6*10^(stimdb/20)*sin(2*pi*F0*t); % unramped stimulus
        pin(1:irpts)=pin(1:irpts).*(0:(irpts-1))/irpts; 
        pin((mxpts-irpts):mxpts)=pin((mxpts-irpts):mxpts).*(irpts:-1:0)/irpts;

        vihc = catmodel_IHC(pin,CF,nrep,1/Fs,T*2,cohc,cihc); 
        [synout,psth] = catmodel_Synapse(vihc,CF,nrep,1/Fs,fiberType,implnt); 
        
        rate_matrix(k,j) = sum( psth( 1: (length(psth)/2) ) ); 
        timePSTH = length(psth)/Fs;
        
    end
end
rate_matrix = rate_matrix / nrep;
rate_matrix = rate_matrix / ((length(psth)/Fs)/2);


% Plotting Rate vs Intensity of 'ah' and that of 550 Hz ANF for stimulus at BF

figure(4)
grid on;
hold on;
plot((-20:5:100), rate_matrix2);         % for the ah stimuylus
[~, idx_550] = min(abs(ANF - 550));
plot((-20:5:100), rate_matrix(idx_550,:));  % for the 550Hz ANF, stim @ BF 
xlabel('Intensity');
ylabel('Rate');
title('Rate vs Intensity');
legend('ah','550Hz');


% Recording for all ANFs at 3 dB levels

% taking the 3 intensities as 0dB, 35dB, and 70dB
fwTime = length(fivewo)/Fs;
rate_0 = zeros(22,fwTime*Fs*2);
rate_35 = zeros(22,fwTime*Fs*2);
rate_70 = zeros(22,fwTime*Fs*2);

% playing fivewo for the ANFs
for i = 4:25
    CF = ANF(i);
    Input = fivewo .* 10^(-75/20);
    vihc = catmodel_IHC(Input,CF,nrep,1/Fs,fwTime*2,cohc,cihc); 
    [synout,psth] = catmodel_Synapse(vihc,CF,nrep,1/Fs,fiberType,implnt); 
    rate_0(i-3,:) = psth;
end

for i = 4:25
    CF = ANF(i);
    Input = fivewo .* 10^(-45/20);
    vihc = catmodel_IHC(Input,CF,nrep,1/Fs,fwTime*2,cohc,cihc); 
    [synout,psth] = catmodel_Synapse(vihc,CF,nrep,1/Fs,fiberType,implnt); 
    rate_35(i-3,:) = psth;
end

for i = 4:25
    CF = ANF(i);
    Input = fivewo .* 10^(-5/20);
    vihc = catmodel_IHC(Input,CF,nrep,1/Fs,fwTime*2,cohc,cihc); 
    [synout,psth] = catmodel_Synapse(vihc,CF,nrep,1/Fs,fiberType,implnt); 
    rate_70(i-3,:) = psth;
end


% Plotting the actual spectrogram and the average ANF response rates

figure(5)
spectrogram(fivewo, hann(25.6e-3*Fs), 12.8e-3*Fs, 1:8000, Fs, 'yaxis');
title('Spectrogram for the speech signal');

wind_ms = [3.2, 6.4, 12.8, 25.6, 51.2, 102.4]; % window sizes in ms
wind = 1e-3 * Fs * wind_ms;  % convert to number of samples

% wind(i) has the number of samples in each window
winShift = floor(wind/2);

F = ANF(4:25);
for w = 1:6      % for each window size
    t2 = wind(w)/2 : winShift(w) : length(fivewo)-wind(w)/2;
    avg_rates = zeros(length(F), length(t2));
    for f = 1:22 % for each ANF CF
        for i = 1:length(t2) % b for bin number
            xo = rate_70(f,(t2(i)-winShift(w)+1):(t2(i)+winShift(w)));
            avg_rates(f,i) = sum(xo)*Fs / wind(w);
        end
    end
    figure(6);
    subplot(2,3,w);
    
    [ tim, frq ] = meshgrid( t2, F);
    surf(tim, frq, avg_rates/nrep,'edgecolor','none');
    set(gca,'xtick',[]);set(gca,'ytick',[]);xlabel([]);ylabel([]);colorbar('off');
    xlim([0,1.5e5]);
    title(['Window Size = ',num2str(wind(w)/(1e-3*Fs)),'ms']);
    xlabel('Time');
    ylabel('Frequency');
    view(2);
end






%% Question-3 for 1 band and 8 band sound

filename_wav = 'fivewo_op_8band.wav';
%filename_wav = 'fivewo_op_1band.wav'; % for 1 band sound
Fs = 100e3;  % Sampling frequency (100 kHz)
[fivewo, fs] = audioread(filename_wav);
fivewo = fivewo';
fwTime = length(fivewo)/Fs;  % Total duration of stimulus
nrep = 80;     % 80 stimulus repeats
cohc  = 1.0;   % Normal OHC function
cihc  = 1.0;   % Normal IHC function
fiberType = 3; % High spontaneous rate fiber
implnt = 0;    % Implementation flag

% Define the ANF CFs
h = (0:1/8:7);
ANF = 62.5 * (2.^h);  % Characteristic frequencies from 62.5 Hz to 8 kHz

% Define BF selections for Figures 7 & 8
BF_fig7 = [100, 200, 400, 800, 1600, 3200];  % Figure 7 BFs
BF_fig8 = 100 * 2.^([1:6]/2);  % Figure 8 BFs: geometric progression

% Find the indices of closest matches in ANF array
[~, nF_figure7] = min(abs(ANF' - BF_fig7), [], 1);
[~, nF_figure8] = min(abs(ANF' - BF_fig8), [], 1);

% Compute PSTH responses for selected ANFs
rate_70 = zeros(54, fwTime * Fs * 2);
for i = 4:57  % Loop over ANFs
    CF = ANF(i);
    Input = fivewo .* 10^(-5/20);  % Normalize input
    vihc = catmodel_IHC(Input, CF, nrep, 1/Fs, fwTime*2, cohc, cihc); 
    [synout, psth] = catmodel_Synapse(vihc, CF, nrep, 1/Fs, fiberType, implnt); 
    rate_70(i-3, :) = psth;
end

% Spectrogram Plot
figure(7);
spectrogram(fivewo, hann(12.8e-3*Fs), 6.4e-3*Fs, 1:8000, Fs, 'yaxis');
view(3);
hold on;

% Windowed FFT Analysis and Dominant Frequency Detection
win = 12.8e-3 * Fs;  % 12.8 ms window
wshift = floor(win / 2);  % 50% overlap
t3 = win/2 : wshift : length(fivewo)-win/2;  % Time centers of windows

% Threshold criterion for valid dominant frequency
threshold_factor = 3;  % Peak must be at least 3x mean FFT magnitude

% Color maps for Figures 7 & 8
cmap1 = hsv(length(nF_figure7));
cmap2 = hsv(length(nF_figure8));

% Compute FFTs and plot asterisks for Figure 7
for f = 1 : length(nF_figure7)
    fre_pt = NaN(1, length(t3));  % Initialize with NaNs
    for i = 6 : length(t3)
        Xp = rate_70(nF_figure7(f), (t3(i)-wshift+1) : (t3(i)+wshift));
        m = mean(Xp);  % Remove DC component
        FFT = abs(fft(Xp - m));  % Compute FFT
        [M, I] = max(FFT(1:length(FFT)/2));  % Find peak
        if M > threshold_factor * mean(FFT)  % Apply threshold criterion
            fre_pt(i) = I * Fs / length(FFT);  % Valid dominant frequency
        end
    end
    figure(7);
    plot3(t3/Fs, fre_pt/1000, zeros(1,length(t3))-10, '*', 'Color', cmap1(f,:));
    ylim([0 3]); hold on;
end
view(2);  % 2D view

% Compute FFTs and plot asterisks for Figure 8
figure(8);
spectrogram(fivewo, hann(12.8e-3*Fs), 6.4e-3*Fs, 1:8000, Fs, 'yaxis');
view(3);
hold on;

for f = 1 : length(nF_figure8)
    fre_pt = NaN(1, length(t3));  % Initialize with NaNs
    for i = 6 : length(t3)
        Xp = rate_70(nF_figure8(f), (t3(i)-wshift+1) : (t3(i)+wshift));
        m = mean(Xp);
        FFT = abs(fft(Xp - m));
        [M, I] = max(FFT(1:length(FFT)/2));
        if M > threshold_factor * mean(FFT)  % Apply threshold
            fre_pt(i) = I * Fs / length(FFT);
        end
    end
    figure(8);
    plot3(t3/Fs, fre_pt/1000, zeros(1,length(t3))-10, '*', 'Color', cmap2(f,:));
    ylim([0 3]); hold on;
end
view(2);  % 2D view
