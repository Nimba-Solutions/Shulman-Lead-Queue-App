import { subscribe as empSubscribe, unsubscribe as empUnsubscribe, onError } from 'lightning/empApi';
import { publish, subscribe as lmsSubscribe, unsubscribe as lmsUnsubscribe, APPLICATION_SCOPE } from 'lightning/messageService';
import LEAD_QUEUE_REFRESH from '@salesforce/messageChannel/LeadQueueRefresh__c';
import { CDC_RELEVANT_FIELDS, buildRefreshPayload } from 'c/leadQueueRefreshConfig';

let hasRegisteredEmpErrorHandler = false;

export class LeadQueueRefreshManager {
    constructor(component, options = {}) {
        this.component = component;
        this.messageContext = options.messageContext || null;
        this.onRefresh = options.onRefresh || null;
        this.cdcChannel = options.cdcChannel || '/data/litify_pm__Intake__ChangeEvent';
        this.cdcRelevantFields = options.cdcRelevantFields || new Set(CDC_RELEVANT_FIELDS);
        this.empSubscription = null;
        this.lmsSubscription = null;
        this.eventRefreshTimeout = null;
        this.lmsOriginId = options.originId || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        this.storageKey = options.storageKey || 'leadQueueRefresh';
        this.storageListener = this.handleStorageEvent.bind(this);
        this.storageSupported = typeof window !== 'undefined'
            && typeof window.addEventListener === 'function'
            && typeof window.removeEventListener === 'function'
            && window.localStorage;
        this.broadcastChannel = this.initializeBroadcastChannel();
    }

    setMessageContext(messageContext) {
        this.messageContext = messageContext;
        if (this.messageContext && !this.lmsSubscription) {
            this.subscribeToMessageChannel();
        }
    }

    connect() {
        this.subscribeToRefreshEvents();
        this.subscribeToMessageChannel();
        this.registerStorageListener();
    }

    disconnect() {
        if (this.eventRefreshTimeout) {
            clearTimeout(this.eventRefreshTimeout);
            this.eventRefreshTimeout = null;
        }
        this.unsubscribeFromRefreshEvents();
        this.unsubscribeFromMessageChannel();
        this.unregisterStorageListener();
        this.closeBroadcastChannel();
    }

    publish(action) {
        const payload = buildRefreshPayload({
            action,
            originId: this.lmsOriginId,
            source: 'leadQueueViewer'
        });
        if (!this.messageContext) {
            this.publishToStorage(payload);
            return;
        }
        publish(this.messageContext, LEAD_QUEUE_REFRESH, payload);
        this.publishToBroadcast(payload);
        this.publishToStorage(payload);
    }

    subscribeToRefreshEvents() {
        if (this.empSubscription) {
            return;
        }
        empSubscribe(this.cdcChannel, -1, (message) => {
            this.handleCdcMessage(message);
        }).then((subscription) => {
            this.empSubscription = subscription;
        }).catch((error) => {
            console.error('Failed to subscribe to Lead Queue CDC events:', error);
        });

        if (!hasRegisteredEmpErrorHandler) {
            onError((error) => {
                console.error('Lead Queue CDC error:', error);
            });
            hasRegisteredEmpErrorHandler = true;
        }
    }

    unsubscribeFromRefreshEvents() {
        if (!this.empSubscription) {
            return;
        }
        empUnsubscribe(this.empSubscription, () => {
            this.empSubscription = null;
        });
    }

    subscribeToMessageChannel() {
        if (this.lmsSubscription || !this.messageContext) {
            return;
        }
        this.lmsSubscription = lmsSubscribe(this.messageContext, LEAD_QUEUE_REFRESH, (payload) => {
            this.handleLmsMessage(payload);
        }, { scope: APPLICATION_SCOPE });
    }

    unsubscribeFromMessageChannel() {
        if (!this.lmsSubscription) {
            return;
        }
        lmsUnsubscribe(this.lmsSubscription);
        this.lmsSubscription = null;
    }

    scheduleEventRefresh() {
        if (this.eventRefreshTimeout) {
            return;
        }
        this.eventRefreshTimeout = setTimeout(() => {
            this.eventRefreshTimeout = null;
            if (typeof this.onRefresh === 'function') {
                this.onRefresh();
            }
        }, 500);
    }

    handleCdcMessage(message) {
        const payload = message?.data?.payload;
        const header = payload?.ChangeEventHeader;
        if (!header) {
            return;
        }
        if (header.changeType && header.changeType !== 'UPDATE') {
            this.scheduleEventRefresh();
            return;
        }
        const changedFields = header.changedFields;
        if (!Array.isArray(changedFields) || changedFields.length === 0) {
            this.scheduleEventRefresh();
            return;
        }
        const hasRelevantChange = changedFields.some((fieldName) => this.cdcRelevantFields.has(fieldName));
        if (hasRelevantChange) {
            this.scheduleEventRefresh();
        }
    }

    handleLmsMessage(payload) {
        if (!payload || payload.originId === this.lmsOriginId) {
            return;
        }
        this.scheduleEventRefresh();
    }

    registerStorageListener() {
        if (!this.storageSupported) {
            return;
        }
        window.addEventListener('storage', this.storageListener);
    }

    unregisterStorageListener() {
        if (!this.storageSupported) {
            return;
        }
        window.removeEventListener('storage', this.storageListener);
    }

    publishToStorage(payload) {
        if (!this.storageSupported || !payload) {
            return;
        }
        try {
            window.localStorage.setItem(this.storageKey, JSON.stringify(payload));
        } catch (error) {
            // Ignore storage errors to avoid blocking UI actions.
        }
    }

    handleStorageEvent(event) {
        if (!event || event.key !== this.storageKey || !event.newValue) {
            return;
        }
        try {
            const payload = JSON.parse(event.newValue);
            if (payload && payload.originId === this.lmsOriginId) {
                return;
            }
        } catch (error) {
            return;
        }
        this.scheduleEventRefresh();
    }

    initializeBroadcastChannel() {
        if (typeof BroadcastChannel !== 'function') {
            return null;
        }
        try {
            const channel = new BroadcastChannel(this.storageKey);
            channel.onmessage = (event) => {
                this.handleBroadcastMessage(event?.data);
            };
            return channel;
        } catch (error) {
            return null;
        }
    }

    closeBroadcastChannel() {
        if (!this.broadcastChannel) {
            return;
        }
        try {
            this.broadcastChannel.close();
        } catch (error) {
            // Ignore channel close errors.
        }
        this.broadcastChannel = null;
    }

    publishToBroadcast(payload) {
        if (!this.broadcastChannel || !payload) {
            return;
        }
        try {
            this.broadcastChannel.postMessage(payload);
        } catch (error) {
            // Ignore broadcast errors to avoid blocking UI actions.
        }
    }

    handleBroadcastMessage(payload) {
        if (!payload || payload.originId === this.lmsOriginId) {
            return;
        }
        this.scheduleEventRefresh();
    }
}
