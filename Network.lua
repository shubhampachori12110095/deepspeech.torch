require 'optim'
require 'nnx'
require 'BRNN'
require 'ctchelpers'
require 'gnuplot'
require 'xlua'
require 'utils_multi_gpu'
require 'loader'
local threads = require 'threads'

local WERCalculator = require 'WERCalculator'
local Network = {}
local logger = optim.Logger('train.log')
logger:setNames { 'loss', 'WER' }
logger:style { '-', '-' }


function Network:init(networkParams)
    self.fileName = networkParams.fileName -- The file name to save/load the network from.
    self.nGPU = networkParams.nGPU
    self.lmdb_path = networkParams.lmdb_path
    self.val_path = networkParams.val_path
    WERCalculator:init(networkParams.val_path)
    -- setting model saving/loading
    if (self.loadModel) then
        assert(networkParams.fileName, "Filename hasn't been given to load model.")
        self:loadNetwork(networkParams.fileName)
    else
        assert(networkParams.modelName, "Must have given a model to train.")
        self:prepSpeechModel(networkParams.modelName, networkParams.backend)
    end
    if self.nGPU > 0 then
        self.model:cuda()
        if networkParams.backend == 'cudnn' then
            require 'cudnn'
            cudnn.fastest = true
            cudnn.convert(self.model, cudnn)
        end
    end
    print (self.model)
    self.model:training()
    assert((networkParams.saveModel or networkParams.loadModel) and networkParams.fileName, "To save/load you must specify the fileName you want to save to")
    -- setting online loading
    self.indexer = indexer(networkParams.lmdb_path, networkParams.batch_size)
    self.pool = threads.Threads(1,function() require 'loader' end)
end

function Network:prepSpeechModel(modelName, backend)
    local model = require (modelName)
    self.model = model(self.nGPU, backend)
end

-- Returns a prediction of the input net and input tensors.
function Network:predict(inputTensors)
    local prediction = self.model:forward(inputTensors)
    return prediction
end

local function WERValidationSet(self)
    self.model:evaluate()
    local wer = WERCalculator:calculateValidationWER(self.nGPU>0, self.model)
    self.model:zeroGradParameters()
    self.model:training()
    return wer
end

function Network:trainNetwork(epochs, sgd_params)
    --[[
        train network with self-defined feval (sgd inside); use ctc for evaluation
    --]]

    local lossHistory = {}
    local validationHistory = {}
    local ctcCriterion = nn.CTCCriterion()
    local x, gradParameters = self.model:getParameters()

    -- inputs (preallocate)
    local inputs = torch.Tensor()
    if self.nGPU > 0 then
        ctcCriterion = nn.CTCCriterion():cuda()
        inputs = inputs:cuda()
    end

    -- def loading buf and loader
    local loader = loader(self.lmdb_path)
    local spect_buf, label_buf

    -- load first batch
    local inds = self.indexer:nxt_inds()
    self.pool:addjob(function()
                        return loader:nxt_batch(inds, false)
                    end,
                    function(spect,label)
                        spect_buf=spect
                        label_buf=label
                    end
                    )

    -- ===========================================================
    -- define the feval
    -- ===========================================================
    local function feval(x_new)
        --------------------- data load ------------------------
        self.pool:synchronize()                         -- wait previous loading
        local inputsCPU,targets = spect_buf,label_buf   -- move buf to training data
        inds = self.indexer:nxt_inds()                  -- load nxt batch
        self.pool:addjob(function()
                            return loader:nxt_batch(inds, false)
                        end,
                        function(spect,label)
                            spect_buf=spect
                            label_buf=label
                        end
                        )

        --------------------- fwd and bwd ---------------------
        inputs:resize(inputsCPU:size()):copy(inputsCPU) -- transfer over to GPU
        gradParameters:zero()
        cutorch.synchronize()
        local predictions = self.model:forward(inputs)
        local loss = ctcCriterion:forward(predictions, targets)
        self.model:zeroGradParameters()
        local gradOutput = ctcCriterion:backward(predictions, targets)
        self.model:backward(inputs, gradOutput)
        cutorch.synchronize()
        return loss, gradParameters
    end

    -- ==========================================================
    -- training
    -- ==========================================================
    local currentLoss
    local startTime = os.time()
    local dataSetSize = 20 -- TODO dataset:size()
    local wer = 1
    for i = 1, epochs do
        local averageLoss = 0
        print(string.format("Training Epoch: %d", i))

        -- Periodically update validation error rates
        if (i % 2 == 0 and  self.val_path) then
            wer = WERValidationSet(self)
            if wer then table.insert(validationHistory, 100 * wer) end
        end

        for j = 1, dataSetSize do
            currentLoss = 0
            local _, fs = optim.sgd(feval, x, sgd_params)
            currentLoss = currentLoss + fs[1]
            xlua.progress(j, dataSetSize)
            averageLoss = averageLoss + currentLoss
        end

        averageLoss = averageLoss / dataSetSize -- Calculate the average loss at this epoch.
        table.insert(lossHistory, averageLoss) -- Add the average loss value to the logger.
        print(string.format("Training Epoch: %d Average Loss: %f WER: %.0f%%", i, averageLoss, 100 * wer))

        logger:add { averageLoss, 1000 * wer }
    end

    local endTime = os.time()
    local secondsTaken = endTime - startTime
    local minutesTaken = secondsTaken / 60
    print("Minutes taken to train: ", minutesTaken)

    if (self.saveModel) then
        print("Saving model")
        self:saveNetwork(self.fileName)
    end

    return lossHistory, validationHistory, minutesTaken
end

function Network:testNetwork(test_iter, dict_path)
    require 'mapper'
    local mapper = mapper(dict_path)
    local Evaluator = require 'Evaluator'
    -- Run the test data set through the net and print the results
    local testResults = {}
    local cumWER = 0
    local input = torch.Tensor()
    if (self.nGPU > 0) then input = input:cuda() end

    local loader = loader(self.val_path)
    local indexer = indexer(self.val_path, 1)
    local pool = threads.Threads(1,function()require 'loader'end)
    local inds = indexer:nxt_inds()
    pool:addjob(function()
                    return loader:nxt_batch(inds, true) -- set true to load trans
                end,
                function(spect, label, trans)
                    spect_buf=spect
                    label_buf=label
                    trans_buf=trans
                end
                )
    for i = 1,test_iter do
        pool:synchronize()
        local inputCPU, targets, trans = spect_buf, label_buf, trans_buf
        inds = indexer:nxt_inds()
        pool:addjob(function()
                        return loader:nxt_batch(inds, true)
                    end,
                    function(spect, label, trans)
                        spect_buf=spect
                        label_buf=label
                        trans_buf=trans
                    end
                    )
        -- transfer over to GPU
        input:resize(inputCPU:size()):copy(inputCPU)
        local prediction = Network:predict(input)

        local predictedPhones = Evaluator.getPredictedCharacters(prediction)
        local WER = Evaluator.sequenceErrorRate(targets, predictedPhones)

        local targetPhoneString = ""
        local predictedPhoneString = ""

        -- Turn targets into text string
        for i = 1,#targets[1] do
            local spacer
            if (i < #targets) then spacer = " " else spacer = "" end
            targetPhoneString = targetPhoneString .. mapper.token2alphabet[targets[1][i]] .. spacer
        end

        -- Turn predictions into text string
        for i = 1,#predictedPhones do
            local spacer
            if (i < #predictedPhones) then spacer = " " else spacer = "" end
            predictedPhoneString = predictedPhoneString .. mapper.token2alphabet[predictedPhones[i]] .. spacer
        end
        cumWER = cumWER + WER
        local row = {}
        row.WER = WER
        row.text = trans_buf[1]
        row.predicted = predictedPhoneString
        row.target = targetPhoneString
        table.insert(testResults, row)
        xlua.progress(i, test_iter)
    end

    -- Print the results sorted by WER
    table.sort(testResults, function (a,b) if (a.WER < b.WER) then return true else return false end end)
    for i = 1,#testResults do
        local row = testResults[i]
        print(string.format("WER = %.0f%% | Text = \"%s\" | Predicted characters = \"%s\" | Target characters = \"%s\"",
            row.WER*100, row.text, row.predicted, row.target))
    end
    print("-----------------------------------------")
    print("Individual WER above are from low to high")

    -- Print the overall average PER
    local averageWER = cumWER / test_iter

    print ("\n")
    print(string.format("Testset Word Error Rate : %.0f%%", averageWER*100))
end

function Network:createLossGraph()
    logger:plot()
end

function Network:saveNetwork(saveName)
    saveDataParallel(saveName, self.model)
end

--Loads the model into Network.
function Network:loadNetwork(saveName)
    self.model = loadDataParallel(saveName, self.nGPU)
    model:evaluate()
end

return Network
