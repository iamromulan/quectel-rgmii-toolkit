document.addEventListener("DOMContentLoaded", function () {
  // State management
  const state = {
    isLTECellLockEnabled: false,
    is5GCellLockEnabled: false
  };

  // Constants
  const CONSTANTS = {
    NOTIFICATION_TIMEOUT: 4000,
    SCS_DEFAULT: 'Select SCS',
    ENDPOINTS: {
      CELL_LOCK: '/cgi-bin/cell-locking/cell-lock.sh',
      FETCH_CONFIG: '/cgi-bin/cell-locking/fetch-cell-lock.sh'
    }
  };

  // DOM Elements
  const elements = {
    lteFields: ['earfcn1', 'pci1', 'earfcn2', 'pci2', 'earfcn3', 'pci3'],
    saFields: ['nr-arfcn', 'nr-pci', 'nr-band'],
    buttons: {
      saveLTE: document.getElementById('saveLTE'),
      saveSA: document.getElementById('saveSA'),
      resetLTE: document.getElementById('resetLTE'),
      resetSA: document.getElementById('resetSA'),
      refresh: document.getElementById('refreshConfig')
    }
  };

  // UI Utilities
  const UI = {
    showNotification: (message, isError = false) => {
      const existingNotification = document.querySelector('.notification');
      if (existingNotification) {
        existingNotification.remove();
      }

      const notification = document.createElement('div');
      notification.className = `notification ${isError ? 'is-danger' : 'is-success'} is-light`;
      notification.innerHTML = `
        <button class="delete"></button>
        ${message}
      `;

      document.querySelector('.column-margin').insertAdjacentElement('beforebegin', notification);

      const deleteButton = notification.querySelector('.delete');
      deleteButton.addEventListener('click', () => notification.remove());

      setTimeout(() => notification.remove(), CONSTANTS.NOTIFICATION_TIMEOUT);
    },

    setButtonLoading: (buttonId, isLoading, text = '') => {
      const button = document.getElementById(buttonId);
      if (!button) return;

      button.disabled = isLoading;
      button.innerHTML = isLoading ? `
        <span class="icon is-small">
          <i class="fas fa-spinner fa-pulse"></i>
        </span>
        <span class="ml-2">Processing...</span>
      ` : text;
    },

    toggleInputs: (disabled) => {
      document.querySelectorAll('input, select').forEach(input => {
        input.disabled = disabled;
      });
    },

    clearInputs: (fields) => {
      fields.forEach(fieldId => {
        const element = document.getElementById(fieldId);
        if (element) {
          if (element.tagName === 'SELECT') {
            element.selectedIndex = 0;
          } else {
            element.value = '';
          }
        }
      });
    }
  };

  // Validation Utilities
  const Validator = {
    validateNumeric: (value, fieldName) => {
      if (value && !/^\d+$/.test(value)) {
        UI.showNotification(`${fieldName} must be a numeric value`, true);
        return false;
      }
      return true;
    },

    validateLTEInputs: () => {
      const earfcn1 = document.getElementById('earfcn1').value;
      const pci1 = document.getElementById('pci1').value;

      if (!earfcn1 && !pci1) return true;

      if (!Validator.validateNumeric(earfcn1, 'EARFCN 1')) return false;
      if (!Validator.validateNumeric(pci1, 'PCI 1')) return false;

      if ((earfcn1 && !pci1) || (!earfcn1 && pci1)) {
        UI.showNotification('Both EARFCN and PCI must be provided for each pair', true);
        return false;
      }

      return true;
    },

    validate5GInputs: () => {
      const nrArfcn = document.getElementById('nr-arfcn').value;
      const nrPci = document.getElementById('nr-pci').value;
      const scs = document.getElementById('scs').value;
      const nrBand = document.getElementById('nr-band').value;

      if (!nrArfcn && !nrPci && scs === CONSTANTS.SCS_DEFAULT && !nrBand) return true;

      if (!Validator.validateNumeric(nrArfcn, 'NR ARFCN')) return false;
      if (!Validator.validateNumeric(nrPci, 'NR PCI')) return false;
      if (!Validator.validateNumeric(nrBand, 'NR Band')) return false;

      if (scs === CONSTANTS.SCS_DEFAULT) {
        UI.showNotification('Please select an SCS value', true);
        return false;
      }

      return true;
    }
  };

  // Data Utilities
  const DataUtils = {
    hasValues: (fields) => {
      return fields.some(field => {
        const element = document.getElementById(field);
        if (element.tagName === 'SELECT') {
          return element.value !== CONSTANTS.SCS_DEFAULT;
        }
        return element.value.trim() !== '';
      });
    },

    getFormData: (fields) => {
      return fields.reduce((acc, field) => {
        acc[field] = document.getElementById(field).value;
        return acc;
      }, {});
    }
  };

  // API Handlers
  const API = {
    async makeRequest(endpoint, method = 'GET', body = null) {
      try {
        const response = await fetch(endpoint, {
          method,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded'
          },
          ...(body && { body: new URLSearchParams(body).toString() })
        });
        return await response.json();
      } catch (error) {
        console.error('API Error:', error);
        throw error;
      }
    },

    async saveLTEConfiguration(formData) {
      return API.makeRequest(CONSTANTS.ENDPOINTS.CELL_LOCK, 'POST', formData);
    },

    async save5GConfiguration(formData) {
      return API.makeRequest(CONSTANTS.ENDPOINTS.CELL_LOCK, 'POST', formData);
    },

    async resetConfiguration(type) {
      return API.makeRequest(CONSTANTS.ENDPOINTS.CELL_LOCK, 'POST', {
        [`reset_${type}`]: '1'
      });
    },

    async fetchConfigurations() {
      return API.makeRequest(CONSTANTS.ENDPOINTS.FETCH_CONFIG);
    }
  };

  // Event Handlers
  const EventHandlers = {
    async handleLTESave(e) {
      e.preventDefault();
      if (!Validator.validateLTEInputs()) return;

      if (state.is5GCellLockEnabled || DataUtils.hasValues(elements.saFields)) {
        UI.showNotification('LTE cell lock cannot be configured when 5G-SA cell lock is enabled', true);
        return;
      }

      try {
        UI.toggleInputs(true);
        UI.setButtonLoading('saveLTE', true);

        const formData = DataUtils.getFormData(elements.lteFields);
        const response = await API.saveLTEConfiguration(formData);

        if (response.status === 'success') {
          state.isLTECellLockEnabled = true;
          state.is5GCellLockEnabled = false;
          UI.showNotification('LTE cell lock configured successfully');
        } else {
          UI.showNotification(response.message || 'Error configuring LTE cell lock', true);
        }
      } catch (error) {
        UI.showNotification(`Error configuring LTE cell lock: ${error.message}`, true);
      } finally {
        UI.toggleInputs(false);
        UI.setButtonLoading('saveLTE', false, 'Lock LTE Cells');
      }
    },

    async handle5GSave(e) {
      e.preventDefault();
      if (!Validator.validate5GInputs()) return;

      if (state.isLTECellLockEnabled || DataUtils.hasValues(elements.lteFields)) {
        UI.showNotification('5G-SA cell lock cannot be configured when LTE cell lock is enabled', true);
        return;
      }

      try {
        UI.toggleInputs(true);
        UI.setButtonLoading('saveSA', true);

        const scsValue = document.getElementById('scs').value;
        const formData = {
          nrarfcn: document.getElementById('nr-arfcn').value,
          nrpci: document.getElementById('nr-pci').value,
          scs: scsValue === CONSTANTS.SCS_DEFAULT ? '' : scsValue.split(' ')[0],
          band: document.getElementById('nr-band').value
        };

        const response = await API.save5GConfiguration(formData);

        if (response.status === 'success') {
          state.is5GCellLockEnabled = true;
          state.isLTECellLockEnabled = false;
          UI.showNotification('5G-SA cell lock configured successfully');
        } else {
          UI.showNotification(response.message || 'Error configuring 5G-SA cell lock', true);
        }
      } catch (error) {
        UI.showNotification(`Error configuring 5G-SA cell lock: ${error.message}`, true);
      } finally {
        UI.toggleInputs(false);
        UI.setButtonLoading('saveSA', false, 'Lock 5G-SA Cells');
      }
    },

    async handleLTEReset(e) {
      e.preventDefault();
      try {
        UI.setButtonLoading('resetLTE', true);
        const response = await API.resetConfiguration('lte');

        if (response.status === 'success') {
          UI.clearInputs(elements.lteFields);
          state.isLTECellLockEnabled = false;
          UI.showNotification('LTE cell lock reset successfully');
        } else {
          UI.showNotification(response.message || 'Error resetting LTE cell lock', true);
        }
      } catch (error) {
        UI.showNotification(`Error resetting LTE cell lock: ${error.message}`, true);
      } finally {
        UI.setButtonLoading('resetLTE', false, 'Reset LTE Cells');
      }
    },

    async handle5GReset(e) {
      e.preventDefault();
      try {
        UI.setButtonLoading('resetSA', true);
        const response = await API.resetConfiguration('5g');

        if (response.status === 'success') {
          UI.clearInputs([...elements.saFields, 'scs']);
          state.is5GCellLockEnabled = false;
          UI.showNotification('5G-SA cell lock reset successfully');
        } else {
          UI.showNotification(response.message || 'Error resetting 5G-SA cell lock', true);
        }
      } catch (error) {
        UI.showNotification(`Error resetting 5G-SA cell lock: ${error.message}`, true);
      } finally {
        UI.setButtonLoading('resetSA', false, 'Reset 5G-SA Cells');
      }
    },

    async handleRefresh(e) {
      e?.preventDefault();
      try {
        const data = await API.fetchConfigurations();
        
        if (data.status === 'success' && data.configurations) {
          const { lte, sa } = data.configurations;

          if (lte) {
            state.isLTECellLockEnabled = true;
            state.is5GCellLockEnabled = false;
            elements.lteFields.forEach(field => {
              if (lte[field]) document.getElementById(field).value = lte[field];
            });
          }

          if (sa) {
            state.is5GCellLockEnabled = true;
            state.isLTECellLockEnabled = false;
            elements.saFields.forEach(field => {
              if (sa[field.replace('-', '')]) {
                document.getElementById(field).value = sa[field.replace('-', '')];
              }
            });

            if (sa.scs) {
              const scsSelect = document.getElementById('scs');
              Array.from(scsSelect.options).some((option, index) => {
                if (option.value === sa.scs) {
                  scsSelect.selectedIndex = index;
                  return true;
                }
                return false;
              });
            }
          }
        }
      } catch (error) {
        console.error('Error fetching configurations:', error);
        UI.showNotification(`Error fetching configurations: ${error.message}`, true);
      }
    }
  };

  // Initialize event listeners
  function initializeEventListeners() {
    elements.buttons.saveLTE?.addEventListener('click', EventHandlers.handleLTESave);
    elements.buttons.saveSA?.addEventListener('click', EventHandlers.handle5GSave);
    elements.buttons.resetLTE?.addEventListener('click', EventHandlers.handleLTEReset);
    elements.buttons.resetSA?.addEventListener('click', EventHandlers.handle5GReset);
    elements.buttons.refresh?.addEventListener('click', EventHandlers.handleRefresh);
  }

  // Initialize the application
  function initialize() {
    initializeEventListeners();
    EventHandlers.handleRefresh();
  }

  initialize();
});