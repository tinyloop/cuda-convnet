/* 
 * Copyright (c) 2011, Alex Krizhevsky (akrizhevsky@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * 
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <iostream>
#include "../include/layer_kernels.cuh"
#include "../include/layer.cuh"

using namespace std;

/* 
 * =======================
 * Layer
 * =======================
 */
/*
 * Static variables that control whether the matrices storing the
 * unit activities and their gradients get destroyed after they are used.
 * 
 * Setting these to true might net a performance benefit of a few percent
 * while increasing memory consumption.
 */
bool Layer::_saveActs = true;
bool Layer::_saveActGrads = true;

Layer::Layer(PyObject* paramsDict, bool gradConsumer, bool gradProducer, bool trans) : 
             _gradConsumer(gradConsumer), _gradProducer(gradProducer), _trans(trans) {
    
    _name = pyDictGetString(paramsDict, "name");
    _type = pyDictGetString(paramsDict, "type");
    _numGradProducersNext = 0;
}

void Layer::fpropNext(PASS_TYPE passType) {
    for (int i = 0; i < _next.size(); i++) {
        _next[i]->fprop(passType);
    }
}

void Layer::truncBwdActs() {
    if (!_saveActGrads) { 
        _actGrads.truncate();
    }
    if (!_saveActs) {
        _acts.truncate();
    }
}

void Layer::fprop(PASS_TYPE passType) {
    _rcvdFInputs += 1;
    if (_rcvdFInputs == _prev.size()) {
        NVMatrixV v;
        for (int i = 0; i < _prev.size(); i++) {
            v.push_back(&_prev[i]->getActs());
        }
        fprop(v, passType);
    }
}

void Layer::fprop(NVMatrix& v, PASS_TYPE passType) {
    NVMatrixV vl;
    vl.push_back(&v);
    fprop(vl, passType);
}

// TODO: make this remember v in a class variable, since it's necessary
// for gradient computation. At present bprop just assumes v == prev.getActs().
void Layer::fprop(NVMatrixV& v, PASS_TYPE passType) {
    assert(v.size() == _prev.size());
    _rcvdFInputs = _prev.size();
    for (NVMatrixV::iterator it = v.begin(); it != v.end(); ++it) {
        (*it)->transpose(_trans);
    }
    _acts.transpose(_trans);
    fpropActs(v, passType);
    fpropNext(passType);
}

void Layer::bprop(PASS_TYPE passType) {
    if (_rcvdBInputs == _numGradProducersNext) {
        _rcvdBInputs++; // avoid doing bprop computation twice
        bprop(_actGrads, passType);
    }
}

void Layer::bprop(NVMatrix& v, PASS_TYPE passType) {
    v.transpose(_trans);
    for (int i = 0; i < _prev.size(); i++) {
        _prev[i]->getActs().transpose(_trans);
        _prev[i]->getActGrads().transpose(_trans);
    }
    _acts.transpose(_trans);
    
    bpropCommon(v, passType);
    
    if (_gradProducer) {
        for (int i = 0; i < _prev.size(); i++) {
            if (_prev[i]->isGradConsumer()) {
                bpropActs(v, i, passType);
                _prev[i]->incRcvdBInputs();
            }
        }    
    }
    
    bpropWeights(v, passType);
    truncBwdActs();
    
    if (_gradProducer) {
        for (int i = 0; i < _prev.size(); i++) {
            if (_prev[i]->isGradConsumer()) {
                _prev[i]->bprop(passType);
            }
        }
    }
}

void Layer::reset() {
    _rcvdFInputs = 0;
    _rcvdBInputs = 0;
}

string& Layer::getName() {
    return _name;
}

string& Layer::getType() {
    return _type;
}

int Layer::getRcvdFInputs() {
    return _rcvdFInputs;
}

int Layer::getRcvdBInputs() {
    return _rcvdBInputs;
}

int Layer::incRcvdBInputs() {
    return ++_rcvdBInputs;
}

void Layer::addNext(Layer* l) {
    _next.push_back(l);
    _numGradProducersNext += l->isGradProducer();
}

void Layer::addPrev(Layer* l) {
    _prev.push_back(l);
}

// Propagate gradient through this layer?
bool Layer::isGradConsumer() {
    return _gradConsumer;
}

// Does this layer produce gradient for layers below?
bool Layer::isGradProducer() {
    return _gradProducer;
}

vector<Layer*>& Layer::getPrev() {
    return _prev;
}

vector<Layer*>& Layer::getNext() {
    return _next;
}

NVMatrix& Layer::getActs() {
    return _acts;
}

NVMatrix& Layer::getActGrads() {
    return _actGrads;
}

/* 
 * =======================
 * WeightLayer
 * =======================
 */
WeightLayer::WeightLayer(PyObject* paramsDict, bool gradConsumer, bool gradProducer, bool trans) : 
    Layer(paramsDict, gradConsumer, gradProducer, trans) {
}

void WeightLayer::addWeights(Weights& w) {
    _vWeights.push_back(&w);
}

void WeightLayer::addWeights(WeightList& wl) {
    for (int i = 0; i < wl.getSize(); i++) {
        addWeights(wl[i]);
    }
}

void WeightLayer::updateWeights(int numCases) {
    for (vector<Weights*>::iterator i = _vWeights.begin(); i != _vWeights.end(); ++i) {
        (*i)->update(numCases);
    }
}

void WeightLayer::copyToCPU() {
    for (vector<Weights*>::iterator i = _vWeights.begin(); i != _vWeights.end(); ++i) {
        (*i)->copyToCPU();
    }
}

void WeightLayer::copyToGPU() {
    for (vector<Weights*>::iterator i = _vWeights.begin(); i != _vWeights.end(); ++i) {
        (*i)->copyToGPU();
    }
}

/* 
 * =======================
 * FCLayer
 * =======================
 */
FCLayer::FCLayer(PyObject* paramsDict) : WeightLayer(paramsDict, true, true, true) {
    MatrixV* hWeights = pyDictGetMatrixV(paramsDict, "weights");
    MatrixV* hWeightsInc = pyDictGetMatrixV(paramsDict, "weightsInc");
    Matrix* hBiases = pyDictGetMatrix(paramsDict, "biases");
    Matrix* hBiasesInc = pyDictGetMatrix(paramsDict, "biasesInc");

    floatv* momW = pyDictGetFloatV(paramsDict, "momW");
    float momB = pyDictGetFloat(paramsDict, "momB");
    floatv* epsW = pyDictGetFloatV(paramsDict, "epsW");
    float epsB = pyDictGetFloat(paramsDict, "epsB");
    floatv* wc = pyDictGetFloatV(paramsDict, "wc");
    _weights.initialize(*hWeights, *hWeightsInc, *epsW, *wc, *momW, false);
    _biases.initialize(*hBiases, *hBiasesInc, epsB, 0, momB, true);

    string neuronType = pyDictGetString(paramsDict, "neuron");
    _neuron = &Neuron::makeNeuron(neuronType);
    
    addWeights(_weights);
    addWeights(_biases);
}

void FCLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    v[0]->rightMult(*_weights[0], _acts);
    for (int i = 1; i < v.size(); i++) {
        _acts.addProduct(*v[i], *_weights[i]);
    }
    
    _acts.addVector(*_biases);
    _neuron->activate(_acts);
}

void FCLayer::bpropCommon(NVMatrix& v, PASS_TYPE passType) {
    _neuron->computeInputGrads(v);
}

void FCLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    NVMatrix& weights_T = _weights[inpIdx].getW().getTranspose();
    if (_prev[inpIdx]->getRcvdBInputs() == 0) {
        v.rightMult(weights_T, _prev[inpIdx]->getActGrads());
    } else {
        _prev[inpIdx]->getActGrads().addProduct(v, weights_T);
    }
    delete &weights_T;
}

void FCLayer::bpropWeights(NVMatrix& v, PASS_TYPE passType) {
    v.sum(0, _biases.getGrads());
    for (int i = 0; i < _prev.size(); i++) {
        NVMatrix& prevActs_T = _prev[i]->getActs().getTranspose();
        _weights[i].getInc().addProduct(prevActs_T, v,  (passType != PASS_GC) * _weights[i].getMom(),
                                        passType == PASS_GC ? 1 : _weights[i].getEps() / v.getNumRows());
        delete &prevActs_T;
    }
}

void FCLayer::checkGradients(ConvNet* convNet) {
    for (int i = 0; i < _weights.getSize(); i++) {
        convNet->checkGradientsW(_name + " weights[" + tostr(i) + "]", 0.1, _weights[i]);
    }
    convNet->checkGradientsW(_name + " biases", 0.01, _biases);
}

/* 
 * =======================
 * ConvLayer
 * =======================
 */
ConvLayer::ConvLayer(PyObject* paramsDict) : WeightLayer(paramsDict, true, true, false) {
    Matrix* hWeights = pyDictGetMatrix(paramsDict, "weights");
    Matrix* hWeightsInc = pyDictGetMatrix(paramsDict, "weightsInc");
    Matrix* hBiases = pyDictGetMatrix(paramsDict, "biases");
    Matrix* hBiasesInc = pyDictGetMatrix(paramsDict, "biasesInc");
    
    float momW = pyDictGetFloat(paramsDict, "momW");
    float momB = pyDictGetFloat(paramsDict, "momB");
    float epsW = pyDictGetFloat(paramsDict, "epsW");
    float epsB = pyDictGetFloat(paramsDict, "epsB");
    float wc = pyDictGetFloat(paramsDict, "wc");
    
    _padding = pyDictGetInt(paramsDict, "padding");
    _stride = pyDictGetInt(paramsDict, "stride");
    _filterSize = pyDictGetInt(paramsDict, "filterSize");
    _modulesX = pyDictGetInt(paramsDict, "modulesX");
    _channels = pyDictGetInt(paramsDict, "channels");
    _imgSize = pyDictGetInt(paramsDict, "imgSize");
    _numFilters = pyDictGetInt(paramsDict, "numFilters");
    _partialSum = pyDictGetInt(paramsDict, "partialSum");
    _sharedBiases = pyDictGetInt(paramsDict, "sharedBiases");

    _modules = _modulesX * _modulesX;
    _filterPixels = _filterSize * _filterSize;
    _imgPixels = _imgSize * _imgSize;
    
    _weights.initialize(*hWeights, *hWeightsInc, epsW, wc, momW, true);
    _biases.initialize(*hBiases, *hBiasesInc, epsB, 0, momB, true);

    string neuronType = pyDictGetString(paramsDict, "neuron");
    _neuron = &Neuron::makeNeuron(neuronType);
    
    addWeights(_weights);
    addWeights(_biases);
}

void ConvLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    convFilterActs(*v[0], *_weights, _acts, _modulesX, _padding, _stride, _channels);
    if (_sharedBiases) {
        _acts.reshape(_numFilters, _acts.getNumElements() / _numFilters);
        _acts.addVector(*_biases);
        _acts.reshape(_numFilters * _modules, _acts.getNumElements() / (_numFilters * _modules));
    } else {
        _acts.addVector(*_biases);
    }
    _neuron->activate(_acts);
}

void ConvLayer::bpropCommon(NVMatrix& v, PASS_TYPE passType) {
    _neuron->computeInputGrads(v);
}

void ConvLayer::bpropWeights(NVMatrix& v, PASS_TYPE passType) {
    if (_sharedBiases) {
        v.reshape(_numFilters, v.getNumElements() / _numFilters);
        v.sum(1, _biases.getGrads());
        v.reshape(_numFilters * _modules, v.getNumElements() / (_numFilters * _modules));
    } else {
        v.sum(1, _biases.getGrads());
    }
    if (_partialSum > 0 && _partialSum < _modules) {
        convWeightActs(_prev[0]->getActs(), v, _weightGradsTmp, _modulesX, _filterSize, _padding, _stride, _channels, 0, 1, _partialSum);
        _weightGradsTmp.reshape(_modules / _partialSum, _channels * _filterPixels * _numFilters);
        _weightGradsTmp.sum(0, _weights.getGrads());
        _weights.getGrads().reshape(_channels * _filterPixels, _numFilters);
    } else {
        convWeightActs(_prev[0]->getActs(), v, _weights.getGrads(), _modulesX, _filterSize, _padding, _stride, _channels);
    }
}

void ConvLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    float scaleTargets = _prev[inpIdx]->getRcvdBInputs() == 0 ? 0 : 1;
    convImgActs(v, *_weights, _prev[inpIdx]->getActGrads(), _imgSize, _padding, _stride, _channels, scaleTargets, 1);
}

void ConvLayer::truncBwdActs() {
    Layer::truncBwdActs();
    if (!_saveActGrads) {
        _weightGradsTmp.truncate();
    }
}

void ConvLayer::checkGradients(ConvNet* convNet) {
    convNet->checkGradientsW(_name + " weights", 0.01, _weights);
    convNet->checkGradientsW(_name + " biases", 0.02, _biases);
}

/* 
 * =======================
 * SoftmaxLayer
 * =======================
 */
SoftmaxLayer::SoftmaxLayer(PyObject* paramsDict) : Layer(paramsDict, true, true, true) {
}

void SoftmaxLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    bool doLogregGrad = _next.size() == 1 && _next[0]->getType() == "cost.logreg";
    if (doLogregGrad) {
        NVMatrix& labels = _next[0]->getPrev()[0]->getActs();
        float gradCoeff = dynamic_cast<CostLayer*>(_next[0])->getCoeff();
        computeLogregSoftmaxGrads(labels, _acts, _prev[inpIdx]->getActGrads(), _prev[inpIdx]->getRcvdBInputs() > 0, gradCoeff);
    } else {
        computeSoftmaxGrads(_acts, v, _prev[inpIdx]->getActGrads(), _prev[inpIdx]->getRcvdBInputs() > 0);
    }
}

void SoftmaxLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    NVMatrix& input = *v[0];

    NVMatrix& max = input.max(1);
    input.addVector(max, -1, _acts);
    _acts.apply(NVMatrix::EXP);
    NVMatrix& sum = _acts.sum(1);
    _acts.eltwiseDivideByVector(sum);
    
    delete &max;
    delete &sum;
}

/* 
 * =======================
 * DataLayer
 * =======================
 */
DataLayer::DataLayer(PyObject* paramsDict) : Layer(paramsDict, false, false, false) {
    _dataIdx = pyDictGetInt(paramsDict, "dataIdx");
}

void DataLayer::fprop(PASS_TYPE passType) {
    throw string("No dava given!");
}

void DataLayer::fpropActs(NVMatrixV& data, PASS_TYPE passType) {
    NVMatrix& d = *data[_dataIdx];
    // TODO: this is slightly inelegant because it creates a copy of the data structure
    // (though not of any GPU memory)
    _acts = d;
    // Make sure that _acts knows that it does not own its GPU memory
    _acts.setView(true);
}

void DataLayer::fprop(NVMatrixV& data, PASS_TYPE passType) {
    fpropActs(data, passType);
    fpropNext(passType);
}

/* 
 * =====================
 * PoolLayer
 * =====================
 */
PoolLayer::PoolLayer(PyObject* paramsDict) : Layer(paramsDict, true, true, false) {
    _channels = pyDictGetInt(paramsDict, "channels");
    _sizeX = pyDictGetInt(paramsDict, "sizeX");
    _start = pyDictGetInt(paramsDict, "start");
    _stride = pyDictGetInt(paramsDict, "stride");
    _outputsX = pyDictGetInt(paramsDict, "outputsX");
    _imgSize = pyDictGetInt(paramsDict, "imgSize");
    
    _pool = pyDictGetString(paramsDict, "pool");
    if (_pool != "max" && _pool != "avg") {
        throw string("Unknown pooling type ") + _pool;
    }
}

void PoolLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    NVMatrix& images = *v[0];
    if (_pool == "max") {
        convLocalPool(images, _acts, _channels, _sizeX, _start, _stride, _outputsX, MaxPooler());
    } else if (_pool == "avg") {
        convLocalPool(images, _acts, _channels, _sizeX, _start, _stride, _outputsX, AvgPooler(_sizeX*_sizeX));
    }
}

void PoolLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    float scaleTargets = _prev[inpIdx]->getRcvdBInputs() == 0 ? 0 : 1;

    if (_pool == "max") {
        convLocalMaxUndo(_prev[inpIdx]->getActs(), v, _acts, _prev[inpIdx]->getActGrads(), _sizeX, _start, _stride, _outputsX, scaleTargets, 1);
    } else if (_pool == "avg") {
        convLocalAvgUndo(v, _prev[inpIdx]->getActGrads(), _sizeX, _start, _stride, _outputsX, _imgSize, scaleTargets, 1);
    }
}

/* 
 * =====================
 * ResponseNormLayer
 * =====================
 */
ResponseNormLayer::ResponseNormLayer(PyObject* paramsDict) : Layer(paramsDict, true, true, false) {
    _channels = pyDictGetInt(paramsDict, "channels");
    _sizeX = pyDictGetInt(paramsDict, "sizeX");

    _scale = pyDictGetFloat(paramsDict, "scale");
    _pow = pyDictGetFloat(paramsDict, "pow");
}

void ResponseNormLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    NVMatrix& images = *v[0];
    convResponseNorm(images, _denoms, _acts, _channels, _sizeX, _scale, _pow);
}

void ResponseNormLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    float scaleTargets = _prev[inpIdx]->getRcvdBInputs() == 0 ? 0 : 1;
    convResponseNormUndo(v, _denoms, _prev[inpIdx]->getActs(), _acts, _prev[inpIdx]->getActGrads(), _channels, _sizeX, _scale, _pow, scaleTargets, 1);
}

void ResponseNormLayer::truncBwdActs() {
    Layer::truncBwdActs();
    if (!_saveActs) {
        _denoms.truncate();
    }
}

/* 
 * =====================
 * ContrastNormLayer
 * =====================
 */
ContrastNormLayer::ContrastNormLayer(PyObject* paramsDict) : ResponseNormLayer(paramsDict) {
    _imgSize = pyDictGetInt(paramsDict, "imgSize");
}

void ContrastNormLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    NVMatrix& images = *v[0];
    convLocalPool(images, _meanDiffs, _channels, _sizeX, -_sizeX/2, 1, _imgSize, AvgPooler(_sizeX*_sizeX));
    _meanDiffs.add(images, -1, 1);
    convContrastNorm(images, _meanDiffs, _denoms, _acts, _channels, _sizeX, _scale, _pow);
}

void ContrastNormLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    float scaleTargets = _prev[inpIdx]->getRcvdBInputs() == 0 ? 0 : 1;
    convContrastNormUndo(v, _denoms, _meanDiffs, _acts, _prev[inpIdx]->getActGrads(), _channels, _sizeX, _scale, _pow, scaleTargets, 1);
}

void ContrastNormLayer::truncBwdActs() {
    ResponseNormLayer::truncBwdActs();
    if (!_saveActs) {
        _meanDiffs.truncate();
    }
}

/* 
 * =====================
 * CostLayer
 * =====================
 */
CostLayer::CostLayer(PyObject* paramsDict, bool gradConsumer, bool gradProducer, bool trans) 
    : Layer(paramsDict, gradConsumer, gradProducer, trans) {
    _coeff = pyDictGetFloat(paramsDict, "coeff");
    _gradProducer = _coeff != 0;
}

float CostLayer::getCoeff() {
    return _coeff;
}

void CostLayer::bprop(PASS_TYPE passType) {
    if (_coeff != 0) {
        Layer::bprop(passType);
    }
}

doublev& CostLayer::getError() {
    doublev& v = *new doublev();
    v.insert(v.begin(), _err.begin(), _err.end());
    return v;
}

// TODO: make this a factory object
CostLayer& CostLayer::makeCostLayer(string& type, PyObject* paramsDict) {
    if (type == "cost.logreg") {
        return *new LogregCostLayer(paramsDict);
    }
    throw string("Unknown cost layer type ") + type;
}

/* 
 * =====================
 * LogregCostLayer
 * =====================
 */
LogregCostLayer::LogregCostLayer(PyObject* paramsDict) : CostLayer(paramsDict, true, true, false) {
}

void LogregCostLayer::fpropActs(NVMatrixV& v, PASS_TYPE passType) {
    _err.clear();
    NVMatrix& labels = *v[0];
    NVMatrix& probs = *v[1];
    int numCases = labels.getNumElements();
    
    NVMatrix& trueLabelLogProbs = _acts, correctProbs;
    computeLogregCost(labels, probs, trueLabelLogProbs, correctProbs);
    _err.push_back(-trueLabelLogProbs.sum());
    _err.push_back(numCases - correctProbs.sum());
}

void LogregCostLayer::bpropActs(NVMatrix& v, int inpIdx, PASS_TYPE passType) {
    NVMatrix& labels = _prev[0]->getActs();
    NVMatrix& probs = _prev[inpIdx]->getActs();
    NVMatrix& target = _prev[inpIdx]->getActGrads();
    // Numerical stability optimization: if the layer below me is a softmax layer, let it handle
    // the entire gradient computation to avoid multiplying and dividing by a near-zero quantity.
    bool doWork = _prev[inpIdx]->getNext().size() > 1 || _prev[inpIdx]->getType() != "softmax";
    if (doWork) {
        computeLogregGrads(labels, probs, target, _prev[inpIdx]->getRcvdBInputs() > 0, _coeff);
    }
}