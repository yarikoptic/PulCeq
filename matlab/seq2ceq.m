function ceq = seq2ceq(seqarg, varargin)
% function ceq = seq2ceq(seq)
%
% Convert a Pulseq file (http://pulseq.github.io/) to a PulCeq struct.
% See github/HarmonizedMRI/PulCeq/src/pulCeq.h
%
% Input
%   seqarg     a seq object, or name of a .seq file
%
% Output
%   ceq        struct, similar to github/HarmonizedMRI/PulCeq/src/pulCeq.h


%% parse inputs

% defaults
arg.verbose = false;
arg.nMax    = [];
arg.ignoreSegmentLabels = false; % Don't define segments using the EXT column

% Substitute specified system values as appropriate (from MIRT toolbox)
arg = vararg_pair(arg, varargin);


%% Get seq object
if isa(seqarg, 'char')
    seq = mr.Sequence();
    seq.read(seqarg);
else
    if ~isa(seqarg, 'mr.Sequence')
        error('First argument is not an mr.Sequence object');
    end
    seq = seqarg;
end

nEvents = 7;   % Pulseq 1.4.0 
blockEvents = cell2mat(seq.blockEvents);
blockEvents = reshape(blockEvents, [nEvents, length(seq.blockEvents)]).'; 

% number of blocks (rows in .seq file) to step through
if isempty(arg.nMax)
    ceq.nMax = size(blockEvents, 1);
else
    ceq.nMax = arg.nMax;
end


%% Get parent blocks
% parent blocks = unique up to a scaling factor, or phase/frequency offsets.
% Contains waveforms with maximum amplitude across blocks.
% First find unique blocks, then determine and set max amplitudes.
% parentBlockIDs = vector of parent block IDs for all blocks

parentBlockIndex(1) = 1;  % first block is unique by definition

fprintf('seq2ceq: Getting block %d/%d', 1, ceq.nMax); prev_n = 1; % Progress update trackers
for n = 1:ceq.nMax
    if ~mod(n, 500) || n == ceq.nMax
        for ib = 1:strlength(sprintf('seq2ceq: Getting block %d/%d', prev_n, ceq.nMax))
            fprintf('\b');
        end
        prev_n = n;
        fprintf(sprintf('seq2ceq: Getting block %d/%d', n, ceq.nMax));
        if n == ceq.nMax, fprintf('\n'), end
    end

    % Pure delay blocks are handled separately
    b = seq.getBlock(n);
    if isdelayblock(b)
        parentBlockIDs(n) = 0;
        continue;
    end

    for p = 1:length(parentBlockIndex)
        n2 = parentBlockIndex(p);
        IsSame(p) = compareblocks(seq, blockEvents(n,:), blockEvents(n2,:), n, n2);
    end
    if sum(IsSame) == 0
        if arg.verbose
            fprintf('\nFound new block on line %d\n', n);
        end
        parentBlockIndex(p+1) = n;  % add new block to list
        parentBlockIDs(n) = p+1;
    else
        I = find(IsSame);
        parentBlockIDs(n) = I;
    end
end

ceq.nParentBlocks = length(parentBlockIndex);
for p = 1:length(parentBlockIndex)
    ceq.parentBlocks{p} = seq.getBlock(parentBlockIndex(p));
end

% Determine max amplitude across blocks
for p = 1:length(parentBlockIndex)
    ceq.parentBlocks{p}.amp.rf = 0;
    ceq.parentBlocks{p}.amp.gx = 0;  
    ceq.parentBlocks{p}.amp.gy = 0;
    ceq.parentBlocks{p}.amp.gz = 0;

    for n = 1:ceq.nMax
        if parentBlockIDs(n) ~= p
            continue; 
        end
        block = seq.getBlock(n);
        if ~isempty(block.rf)
            ceq.parentBlocks{p}.amp.rf = max(ceq.parentBlocks{p}.amp.rf, max(abs(block.rf.signal)));
        end
        for ax = {'gx','gy','gz'}
            g = block.(ax{1});
            if ~isempty(g)
                if strcmp(g.type, 'trap')
                    gamp = abs(g.amplitude);   % trapezoids are positive lobes by definition
                else
                    gamp = max(abs(g.waveform));
                end
                ceq.parentBlocks{p}.amp.(ax{1}) = max(ceq.parentBlocks{p}.amp.(ax{1}), gamp);
            end
        end
    end
end

% Set parent block waveform amplitudes to max
for p = 1:ceq.nParentBlocks
    b = ceq.parentBlocks{p};   % shorthand
    if ~isempty(b.rf)
        ceq.parentBlocks{p}.rf.signal = b.rf.signal/max(abs(b.rf.signal))*b.amp.rf;
    end
    for ax = {'gx','gy','gz'}
        g = b.(ax{1});
        if ~isempty(g)
            if strcmp(g.type, 'trap')
                ceq.parentBlocks{p}.(ax{1}).amplitude = b.amp.(ax{1});
            else
                if max(abs(b.(ax{1}).waveform)) > 0
                    ceq.parentBlocks{p}.(ax{1}).waveform = b.(ax{1}).waveform/max(abs(b.(ax{1}).waveform))*b.amp.(ax{1});
                end
            end
        end
    end
end

%% Get segment (block group) definitions
% Define the following:
%  ceq.groups
%  blockGroupIDs: length-n vector containing segment IDs
currentSegmentID = []; 
if ~arg.ignoreSegmentLabels
    blockGroupIDs = zeros(1,ceq.nMax);  % keep track of which segment each block belongs to
    for n = 1:ceq.nMax

        b = seq.getBlock(n);

        if isfield(b, 'label')
            % wrap up the current segment
            if ~isempty(currentSegmentID) | n == ceq.nMax
                Segments{currentSegmentID} = [currentSegmentID length(blockIDs) blockIDs];
            end

            % start new segment
            currentSegmentID = b.label.value;
            blockIDs = parentBlockIDs(n); 
        else
            % add block to this block group
            blockIDs = [blockIDs parentBlockIDs(n)];
        end

        blockGroupIDs(n) = currentSegmentID;
    end
else
    % Each block becomes its own segment (as in TOPPE v5)
    for p = 1:ceq.nParentBlocks
        ceq.groups(p).groupID = p;
        ceq.groups(p).nBlocksInGroup = 1;
        ceq.groups(p).blockIDs = p;
    end

    % Add delay segment (dedicated segment that's always defined)
    ceq.groups(p+1).groupID = p+1;
    ceq.groups(p+1).nBlocksInGroup = 1;
    ceq.groups(p+1).blockIDs = 0;   % block ID zero is a flag indicating a delay block

    blockGroupIDs = parentBlockIDs;
    blockGroupIDs(parentBlockIDs==0) = p+1;

    segmentID2Ind = 1:(p+1);
end

%currentSegmentID = [];  
%if ~isempty(currentSegmentID)
if ~arg.ignoreSegmentLabels
    % In the above, the Segments array index equals the Segment ID specified in the .seq file.
    % Now we squash the Segments array and redefine the Segment IDs accordingly;
    % this is needed since the interpreter assumes that segment ID = index into segment array.
    iSeg = 1;    % segment array index
    for segmentID = 1:length(Segments)
        if ~isempty(Segments{segmentID})
            segmentID2Ind(segmentID) = iSeg;
            ceq.groups(iSeg).groupID = iSeg;
            ceq.groups(iSeg).nBlocksInGroup = Segments{segmentID}(2);
            ceq.groups(iSeg).blockIDs = Segments{segmentID}(3:end);
            iSeg = iSeg + 1;
        end
    end
end

ceq.nGroups = length(ceq.groups);


%% Get dynamic scan information
ceq.loop = zeros(ceq.nMax, 10);
for n = 1:ceq.nMax
    b = seq.getBlock(n);
    p = parentBlockIDs(n); 
    if p == 0  % delay block
        ceq.loop(n,:) = getdynamics(b, segmentID2Ind(blockGroupIDs(n)), p);
    else
        ceq.loop(n,:) = getdynamics(b, segmentID2Ind(blockGroupIDs(n)), p, ceq.parentBlocks{p});
    end
end

%% Check that the execution of blocks throughout the sequence
%% is consistent with the segment definitions
n = 1;
while n < ceq.nMax
    i = ceq.loop(n, 1);  % segment id
    for j = 1:ceq.groups(i).nBlocksInGroup
        p = ceq.loop(n, 2);  % parent block id
        p_ij = ceq.groups(i).blockIDs(j);
        if p ~= p_ij
            error(sprintf('Expected parent block ID %d, found %d (block %d)', p_ij, p, n));
        end
        n = n + 1;
    end
end

%fprintf('\n');
